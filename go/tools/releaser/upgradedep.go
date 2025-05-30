// Copyright 2021 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"

	bzl "github.com/bazelbuild/buildtools/build"
	"github.com/google/go-github/v36/github"
	"golang.org/x/mod/semver"
	"golang.org/x/oauth2"
	"golang.org/x/sync/errgroup"
)

var upgradeDepCmd = command{
	name:        "upgrade-dep",
	description: "upgrades a dependency in WORKSPACE or go_repositories.bzl",
	help: `releaser upgrade-dep [-githubtoken=token] [-mirror] [-work] deps...

upgrade-dep upgrades one or more rules_go dependencies in WORKSPACE or
go/private/repositories.bzl. Dependency names (matching the name attributes)
can be specified with positional arguments. They may have a suffix of the form
'@version' to request update to a specific version.
"all" may be specified to upgrade all upgradeable dependencies.

For each dependency, upgrade-dep finds the highest version available in the
upstream repository. If no version is available, upgrade-dep uses the commit
at the tip of the default branch. If a version is part of a release,
upgrade-dep will try to use an archive attached to the release; if none is
available, upgrade-dep uses an archive generated by GitHub.

Once upgrade-dep has found the URL for the latest version, it will:

* Download the archive.
* Upload the archive to mirror.bazel.build.
* Re-generate patches, either by running a command or by re-applying the
  old patches.
* Update dependency attributes in WORKSPACE and repositories.bzl, then format
  and rewrite those files.

Upgradeable dependencies need a comment like '# releaser:upgrade-dep org repo'
where org and repo are the GitHub organization and repository. We could
potentially fetch archives from proxy.golang.org instead, but it's not available
in as many countries.

Patches may have a comment like '# releaser:patch-cmd name args...'. If this
comment is present, upgrade-dep will generate the patch by running the specified
command in a temporary directory containing the extracted archive with the
previous patches applied.
`,
}

func init() {
	// break init cycle
	upgradeDepCmd.run = runUpgradeDep
}

// parseDepArg parses a dependency argument like org_golang_x_sys@v0.30.0
// into the dependency name and version.
// If there is no @, the arg will be returned unchanged and the version
// will be an empty string.
func parseDepArg(arg string) (string, string) {
	i := strings.Index(arg, "@")
	if i < 0 {
		return arg, ""
	}
	return arg[:i], arg[i+1:]
}

func runUpgradeDep(ctx context.Context, stderr io.Writer, args []string) error {
	// Parse arguments.
	flags := flag.NewFlagSet("releaser upgrade-dep", flag.ContinueOnError)
	var githubToken githubTokenFlag
	var uploadToMirror, leaveWorkDir bool
	flags.Var(&githubToken, "githubtoken", "GitHub personal access token or path to a file containing it")
	flags.BoolVar(&uploadToMirror, "mirror", true, "whether to upload dependency archives to mirror.bazel.build")
	flags.BoolVar(&leaveWorkDir, "work", false, "don't delete temporary work directory (for debugging)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() == 0 {
		return usageErrorf(&upgradeDepCmd, "No dependencies specified")
	}
	upgradeAll := false
	for _, arg := range flags.Args() {
		if arg == "all" {
			upgradeAll = true
			break
		}
	}
	if upgradeAll && flags.NArg() != 1 {
		return usageErrorf(&upgradeDepCmd, "When 'all' is specified, it must be the only argument")
	}

	httpClient := http.DefaultClient
	if githubToken != "" {
		ts := oauth2.StaticTokenSource(&oauth2.Token{AccessToken: string(githubToken)})
		httpClient = oauth2.NewClient(ctx, ts)
	}
	gh := &githubClient{Client: github.NewClient(httpClient)}

	workDir, err := os.MkdirTemp("", "releaser-upgrade-dep-*")
	if leaveWorkDir {
		fmt.Fprintf(stderr, "work dir: %s\n", workDir)
	} else {
		defer func() {
			if rerr := os.RemoveAll(workDir); err == nil && rerr != nil {
				err = rerr
			}
		}()
	}

	// Make sure we have everything we need.
	// upgrade-dep must be run inside rules_go (though we just check for
	// WORKSPACE), and a few tools must be available.
	rootDir, err := repoRoot()
	if err != nil {
		return err
	}
	for _, tool := range []string{"diff", "gazelle", "patch"} {
		if _, err := exec.LookPath(tool); err != nil {
			return fmt.Errorf("%s must be installed in PATH", tool)
		}
	}

	// Parse and index files we might want to update.
	type file struct {
		path     string
		funcName string
		parsed   *bzl.File
		body     []bzl.Expr
	}
	files := []file{
		{path: filepath.Join(rootDir, "WORKSPACE")},
		{path: filepath.Join(rootDir, "go/private/repositories.bzl"), funcName: "go_rules_dependencies"},
	}
	depIndex := make(map[string]*bzl.CallExpr)

	for i := range files {
		f := &files[i]
		data, err := os.ReadFile(f.path)
		if err != nil {
			return err
		}
		f.parsed, err = bzl.Parse(f.path, data)
		if err != nil {
			return err
		}

		if f.funcName == "" {
			f.body = f.parsed.Stmt
		} else {
			for _, expr := range f.parsed.Stmt {
				def, ok := expr.(*bzl.DefStmt)
				if !ok {
					continue
				}
				if def.Name == f.funcName {
					f.body = def.Body
					break
				}
			}
			if f.body == nil {
				return fmt.Errorf("in file %s, could not find function %s", f.path, f.funcName)
			}
		}

		for _, expr := range f.body {
			call, ok := expr.(*bzl.CallExpr)
			if !ok {
				continue
			}
			for _, arg := range call.List {
				kwarg, ok := arg.(*bzl.AssignExpr)
				if !ok {
					continue
				}
				key := kwarg.LHS.(*bzl.Ident) // required by parser
				if key.Name != "name" {
					continue
				}
				value, ok := kwarg.RHS.(*bzl.StringExpr)
				if !ok {
					continue
				}
				depIndex[value.Value] = call
			}
		}
	}

	// Update dependencies in those files.
	eg, egctx := errgroup.WithContext(ctx)
	if upgradeAll {
		for name := range depIndex {
			name := name
			if _, _, _, err := parseUpgradeDepDirective(depIndex[name]); err != nil {
				continue
			}
			eg.Go(func() error {
				return upgradeDepDecl(egctx, gh, workDir, name, "", depIndex[name], uploadToMirror)
			})
		}
	} else {
		for _, arg := range flags.Args() {
			dep, _ := parseDepArg(arg)
			if depIndex[dep] == nil {
				return fmt.Errorf("could not find dependency %s", arg)
			}
		}
		for _, arg := range flags.Args() {
			arg, ver := parseDepArg(arg)
			eg.Go(func() error {
				return upgradeDepDecl(egctx, gh, workDir, arg, ver, depIndex[arg], uploadToMirror)
			})
		}
	}
	if err := eg.Wait(); err != nil {
		return err
	}

	// Format and write files back to disk.
	for _, f := range files {
		if err := os.WriteFile(f.path, bzl.Format(f.parsed), 0666); err != nil {
			return err
		}
	}
	return nil
}

// upgradeDepDecl upgrades a specific dependency.
func upgradeDepDecl(ctx context.Context, gh *githubClient, workDir, name, version string, call *bzl.CallExpr, uploadToMirror bool) (err error) {
	defer func() {
		if err != nil {
			err = fmt.Errorf("upgrading %s: %w", name, err)
		}
	}()

	// Find a '# releaser:upgrade-dep org repo' comment. We could probably
	// figure this out from URLs but this also serves to mark a dependency as
	// being automatically upgradeable.
	orgName, repoName, relPath, err := parseUpgradeDepDirective(call)
	if err != nil {
		return err
	}

	// Find attributes we'll need to read or write. We'll modify these directly
	// in the AST. Nothing else should read or write them while we're working.
	attrs := map[string]*bzl.Expr{
		"patches":      nil,
		"sha256":       nil,
		"strip_prefix": nil,
		"urls":         nil,
	}
	var urlsKwarg *bzl.AssignExpr
	for _, arg := range call.List {
		kwarg, ok := arg.(*bzl.AssignExpr)
		if !ok {
			continue
		}
		key := kwarg.LHS.(*bzl.Ident) // required by parser
		if _, ok := attrs[key.Name]; ok {
			attrs[key.Name] = &kwarg.RHS
		}
		if key.Name == "urls" {
			urlsKwarg = kwarg
		}
	}
	for key := range attrs {
		if key == "patches" {
			// Don't add optional attributes.
			continue
		}
		if attrs[key] == nil {
			kwarg := &bzl.AssignExpr{LHS: &bzl.Ident{Name: key}, Op: "="}
			call.List = append(call.List, kwarg)
			attrs[key] = &kwarg.RHS
		}
	}

	// Find the highest tag in semver order, ignoring whether the version has a
	// leading "v" or not. If there are no tags, find the commit at the tip of the
	// default branch.
	tags, err := gh.listTags(ctx, orgName, repoName)
	if err != nil {
		return err
	}

	if relPath != "" {
		var filteredTags []*github.RepositoryTag
		for _, tag := range tags {
			if strings.HasPrefix(*tag.Name, relPath+"/") {
				filteredTags = append(filteredTags, tag)
			}
		}
		tags = filteredTags
	}

	vname := func(name string) string {
		name = strings.TrimPrefix(name, relPath+"/")
		if !strings.HasPrefix(name, "v") {
			return "v" + name
		}
		return name
	}

	w := 0
	for r := range tags {
		name := vname(*tags[r].Name)
		if name != semver.Canonical(name) {
			continue
		}
		// Only use pre-release tags if specifically requested.
		if semver.Prerelease(name) != "" && (version == "" || semver.Prerelease(version) == "") {
			continue
		}
		tags[w] = tags[r]
		w++
	}
	tags = tags[:w]

	var highestTag *github.RepositoryTag
	var highestVname string
	for _, tag := range tags {
		name := vname(*tag.Name)
		if version != "" && name == version {
			highestTag = tag
			highestVname = name
			break
		}
		if highestTag == nil || semver.Compare(name, highestVname) > 0 {
			highestTag = tag
			highestVname = name
		}
	}

	var ghURL, stripPrefix, urlComment string
	date := time.Now().Format("2006-01-02")
	if highestTag != nil {
		// Check that this is the tag that was requested.
		if version != "" && highestVname != version {
			err = fmt.Errorf("version %s not found, latest is %s", version, *highestTag.Name)
			return err
		}
		// If the tag is part of a release, check whether there is a release
		// artifact we should use.
		release, _, err := gh.Repositories.GetReleaseByTag(ctx, orgName, repoName, *highestTag.Name)
		if err == nil {
			wantNames := []string{
				fmt.Sprintf("%s-%s.tar.gz", repoName, *highestTag.Name),
				fmt.Sprintf("%s-%s.zip", repoName, *highestTag.Name),
			}
		AssetName:
			for _, asset := range release.Assets {
				for _, wantName := range wantNames {
					if *asset.Name == wantName {
						ghURL = asset.GetBrowserDownloadURL()
						stripPrefix = "" // may not always be correct
						break AssetName
					}
				}
			}
		}
		if ghURL == "" {
			ghURL = fmt.Sprintf("https://github.com/%s/%s/archive/refs/tags/%s.zip", orgName, repoName, *highestTag.Name)
			stripPrefix = repoName + "-" + strings.TrimPrefix(*highestTag.Name, "v")
			stripPrefix = strings.ReplaceAll(stripPrefix, "/", "-")
			if relPath != "" {
				stripPrefix += "/" + relPath
			}
		}

		if version != "" {
			// This tag is not necessarily latest as of today, so get the commit
			// so we can report the actual date.
			commit, _, _ := gh.Repositories.GetCommit(ctx, orgName, repoName, *highestTag.Commit.SHA)
			if commit := commit.GetCommit(); commit != nil {
				if d := commit.Committer.GetDate(); !d.IsZero() {
					date = d.Format("2006-01-02")
				} else if d := commit.Author.GetDate(); !d.IsZero() {
					date = d.Format("2006-01-02")
				}
			}
			urlComment = fmt.Sprintf("%s, from %s", *highestTag.Name, date)
		} else {
			urlComment = fmt.Sprintf("%s, latest as of %s", *highestTag.Name, date)
		}
	} else {
		var commit *github.RepositoryCommit
		if version != "" {
			commit, _, err = gh.Repositories.GetCommit(ctx, orgName, repoName, version)
			if err != nil {
				return err
			}
			date = commit.GetCommit().Committer.GetDate().Format("2006-01-02")
			urlComment = fmt.Sprintf("from %s", date)
		} else {
			repo, _, err := gh.Repositories.Get(ctx, orgName, repoName)
			if err != nil {
				return err
			}
			defaultBranchName := "main"
			if repo.DefaultBranch != nil {
				defaultBranchName = *repo.DefaultBranch
			}
			branch, _, err := gh.Repositories.GetBranch(ctx, orgName, repoName, defaultBranchName)
			if err != nil {
				return err
			}
			commit = branch.Commit
			urlComment = fmt.Sprintf("%s, as of %s", defaultBranchName, date)
		}
		ghURL = fmt.Sprintf("https://github.com/%s/%s/archive/%s.zip", orgName, repoName, *commit.SHA)
		stripPrefix = repoName + "-" + *commit.SHA
	}
	ghURLWithoutScheme := ghURL[len("https://"):]
	mirrorURL := "https://mirror.bazel.build/" + ghURLWithoutScheme

	// Download the archive and find the SHA.
	archiveFile, err := os.CreateTemp("", "")
	if err != nil {
		return err
	}
	defer func() {
		archiveFile.Close()
		if rerr := os.Remove(archiveFile.Name()); err == nil && rerr != nil {
			err = rerr
		}
	}()
	resp, err := http.Get(ghURL)
	if err != nil {
		return err
	}
	hw := sha256.New()
	mw := io.MultiWriter(hw, archiveFile)
	if _, err := io.Copy(mw, resp.Body); err != nil {
		resp.Body.Close()
		return err
	}
	if err := resp.Body.Close(); err != nil {
		return err
	}
	sha256Sum := hex.EncodeToString(hw.Sum(nil))
	if _, err := archiveFile.Seek(0, io.SeekStart); err != nil {
		return err
	}

	// Upload the archive to mirror.bazel.build.
	if uploadToMirror {
		if err := copyFileToMirror(ctx, ghURLWithoutScheme, archiveFile.Name()); err != nil {
			return err
		}
	}

	// If there are patches, re-apply or re-generate them.
	// Patch labels may have "# releaser:patch-cmd name args..." directives
	// that instruct this program to generate the patch by running a commnad
	// in the directory. If there is no such directive, we apply the old patch
	// using "patch". In either case, we'll generate a new patch with "diff".
	// We'll scrub the timestamps to avoid excessive diffs in the PR that
	// updates dependencies.
	rootDir, err := repoRoot()
	if err != nil {
		return err
	}
	if attrs["patches"] != nil {
		if err != nil {
			return err
		}
		patchDir := filepath.Join(workDir, name, "a")
		if err := extractArchive(archiveFile, path.Base(ghURL), patchDir, stripPrefix); err != nil {
			return err
		}

		patchesList, ok := (*attrs["patches"]).(*bzl.ListExpr)
		if !ok {
			return fmt.Errorf("\"patches\" attribute is not a list")
		}
		for patchIndex, patchLabelExpr := range patchesList.List {
			patchLabelValue, comments, err := parsePatchesItem(patchLabelExpr)
			if err != nil {
				return fmt.Errorf("parsing expr %#v : %w", patchLabelExpr, err)
			}

			if !strings.HasPrefix(patchLabelValue, "//third_party:") {
				return fmt.Errorf("patch does not start with '//third_party:': %q", patchLabelValue)
			}
			patchName := patchLabelValue[len("//third_party:"):]
			patchPath := filepath.Join(rootDir, "third_party", patchName)
			prevDir := filepath.Join(workDir, name, string(rune('a'+patchIndex)))
			patchDir := filepath.Join(workDir, name, string(rune('a'+patchIndex+1)))
			var patchCmd []string
			for _, c := range comments.Before {
				words := strings.Fields(strings.TrimPrefix(c.Token, "#"))
				if len(words) > 0 && words[0] == "releaser:patch-cmd" {
					patchCmd = words[1:]
					break
				}
			}

			if err := copyDir(patchDir, prevDir); err != nil {
				return err
			}
			if patchCmd == nil {
				if err := runForError(ctx, patchDir, "patch", "-Np1", "-i", patchPath); err != nil {
					return err
				}
			} else {
				if err := runForError(ctx, patchDir, patchCmd[0], patchCmd[1:]...); err != nil {
					return err
				}
			}
			patch, _ := runForOutput(ctx, filepath.Join(workDir, name), "diff", "-urN", filepath.Base(prevDir), filepath.Base(patchDir))
			patch = sanitizePatch(patch)
			if err := os.WriteFile(patchPath, patch, 0666); err != nil {
				return err
			}
		}
	}

	// Update the attributes.
	*attrs["sha256"] = &bzl.StringExpr{Value: sha256Sum}
	*attrs["strip_prefix"] = &bzl.StringExpr{Value: stripPrefix}
	*attrs["urls"] = &bzl.ListExpr{
		List: []bzl.Expr{
			&bzl.StringExpr{Value: mirrorURL},
			&bzl.StringExpr{Value: ghURL},
		},
		ForceMultiLine: true,
	}
	urlsKwarg.Before = []bzl.Comment{{Token: "# " + urlComment}}

	return nil
}

func parsePatchesItem(patchLabelExpr bzl.Expr) (value string, comments *bzl.Comments, err error) {
	switch patchLabel := patchLabelExpr.(type) {
	case *bzl.CallExpr:
		// Verify the identifier, should be Label
		if ident, ok := patchLabel.X.(*bzl.Ident); !ok {
			return "", nil, fmt.Errorf("invalid identifier while parsing patch label")
		} else if ident.Name != "Label" {
			return "", nil, fmt.Errorf("invalid patch function: %q", ident.Name)
		}

		// Expect 1 String argument with the patch
		if len(patchLabel.List) != 1 {
			return "", nil, fmt.Errorf("Label expr should have 1 argument, found %d", len(patchLabel.List))
		}

		// Parse patch as a string
		patchLabelStr, ok := patchLabel.List[0].(*bzl.StringExpr)
		if !ok {
			return "", nil, fmt.Errorf("Label expr does not contain a string literal")
		}
		return patchLabelStr.Value, patchLabel.Comment(), nil
	case *bzl.StringExpr:
		return strings.TrimPrefix(patchLabel.Value, "@io_bazel_rules_go"), patchLabel.Comment(), nil
	default:
		return "", nil, fmt.Errorf("not all patches are string literals or Label()")
	}
}

// parseUpgradeDepDirective parses a '# releaser:upgrade-dep org repo' directive
// and returns the organization and repository name or an error if the directive
// was not found or malformed.
func parseUpgradeDepDirective(call *bzl.CallExpr) (orgName, repoName, relPath string, err error) {
	// TODO: support other upgrade strategies. For example, support git_repository
	// and go_repository (possibly wrapped in _maybe).
	for _, c := range call.Comment().Before {
		words := strings.Fields(strings.TrimPrefix(c.Token, "#"))
		if len(words) == 0 || words[0] != "releaser:upgrade-dep" {
			continue
		}
		if len(words) == 3 {
			return words[1], words[2], "", nil
		}
		if len(words) == 4 {
			return words[1], words[2], words[3], nil
		}
		return "", "", "", errors.New("invalid upgrade-dep directive; expected org, and name fields with optional rel_path field")
	}
	return "", "", "", errors.New("releaser:upgrade-dep directive not found")
}

// sanitizePatch sets all of the non-zero patch dates to the same value. This
// reduces churn in the PR that updates the patches.
//
// We avoid changing zero-valued patch dates, which are used in added or
// deleted files. Since zero-valued dates can vary a bit by time zone, we assume
// that any year starting with "19" is a zero-valeud date.
func sanitizePatch(patch []byte) []byte {
	lines := bytes.Split(patch, []byte{'\n'})

	for i, line := range lines {
		if !bytes.HasPrefix(line, []byte("+++ ")) && !bytes.HasPrefix(line, []byte("--- ")) {
			continue
		}

		tab := bytes.LastIndexByte(line, '\t')
		if tab < 0 || bytes.HasPrefix(line[tab+1:], []byte("19")) {
			continue
		}

		lines[i] = append(line[:tab+1], []byte("2000-01-01 00:00:00.000000000 -0000")...)
	}
	return bytes.Join(lines, []byte{'\n'})
}
