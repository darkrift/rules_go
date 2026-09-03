# Copyright 2014 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("@bazel_skylib//lib:structs.bzl", "structs")
load(
    "//go/private:context.bzl",
    "validate_nogo",
)
load(
    "//go/private:mode.bzl",
    "LINKMODE_C_ARCHIVE",
    "LINKMODE_C_SHARED",
    "mode_string",
)
load(
    "//go/private:providers.bzl",
    "GoArchive",
    "GoArchiveData",
    "GoInfo",
    "effective_importpath_pkgpath",
)
load(
    "//go/private/actions:compilepkg.bzl",
    "emit_compilepkg",
)
load(
    "//go/private/rules:cgo.bzl",
    "cgo_configure",
)

def _archive_key(archive):
    return (str(archive.data.label), getattr(archive.source, "testfilter", None))

def _archive_closure(archive):
    """Returns actual GoArchive objects in archive's dependency closure."""
    arc_data_list = archive.transitive.to_list()
    edge_count = 0
    for data in arc_data_list:
        edge_count += len(data._dep_labels)
    stack = [archive]
    seen = {}
    closure = []

    # Each unique archive is expanded once. The edge count is an upper bound
    # on the number of additional stack entries, including shared dependencies.
    for _ in [None] * (edge_count + 1):
        if not stack:
            break
        current = stack.pop()
        identity = (_archive_key(current), current.data.file.path)
        if identity in seen:
            continue
        seen[identity] = None
        closure.append(current)
        stack.extend(current.direct)

    if stack:
        fail("dependency cycle while collecting Go archives")
    return closure

def _archives_in_mode(go, archives):
    """Recompiles archives and their dependency closures in go.mode when needed."""
    cache = go._archive_recompile_cache
    if cache == None:
        return archives

    roots = []
    for archive in archives:
        key = _archive_key(archive)
        if key in cache:
            continue
        if archive.source.mode != go.mode:
            roots.append(archive)
            continue

        # Reuse complete dependency branches that are already in the desired
        # mode. If two such branches contain independently recompiled copies of
        # the same package, keep the first branch canonical and rebuild the
        # conflicting branch against it below.
        closure = _archive_closure(archive)
        conflict = False
        for current in closure:
            current_key = _archive_key(current)
            if current_key in cache and cache[current_key].data.file != current.data.file:
                conflict = True
                break
        if conflict:
            roots.append(archive)
        else:
            for current in closure:
                cache[_archive_key(current)] = current

    if roots:
        arc_data_list = depset(transitive = [archive.transitive for archive in roots]).to_list()
        label_to_arc_data = {data.label: data for data in arc_data_list}

        # Build a depth-first post-order list without recursion. Starlark has
        # neither recursive calls nor while loops, so iterate over a list long
        # enough for every archive to be pushed before and after its deps.
        dep_list = []
        stack = [archive.data.label for archive in roots]
        DEPS_UNPROCESSED = -1
        deps_pushed = {label: DEPS_UNPROCESSED for label in stack}
        dependents = {label: [] for label in stack}

        for _ in [None] * (2 * len(arc_data_list)):
            if not stack:
                break

            label = stack.pop()
            if deps_pushed[label] == 0:
                dep_list.append(label)
                for parent in dependents.get(label, []):
                    deps_pushed[parent] -= 1
                    if deps_pushed[parent] == 0:
                        stack.append(parent)
                continue

            deps_pushed[label] = 0
            for child in label_to_arc_data[label]._dep_labels:
                child_key = (str(child), None)
                if child_key in cache:
                    continue
                if child not in deps_pushed:
                    stack.append(child)
                    deps_pushed[child] = DEPS_UNPROCESSED
                    deps_pushed[label] += 1
                    dependents[child] = [label]
                elif deps_pushed[child] != 0:
                    deps_pushed[label] += 1
                    dependents[child].append(label)
            if deps_pushed[label] == 0:
                stack.append(label)

        if stack:
            fail("dependency cycle while recompiling Go archives in the consuming mode")

        for label in dep_list:
            key = (str(label), None)
            if key in cache:
                continue
            data = label_to_arc_data[label]
            direct = [cache[(str(dep), None)] for dep in data._dep_labels]
            package_metadata = getattr(data, "_package_metadata", None)
            source = GoInfo(
                name = data.name,
                label = data.label,
                importpath = data.importpath,
                importmap = data.importmap,
                importpath_aliases = data.importpath_aliases,
                pathtype = data.pathtype,
                testfilter = None,
                is_main = False,
                mode = go.mode,
                srcs = list(data.srcs),
                cover = data._cover,
                embedsrcs = list(data._embedsrcs),
                x_defs = dict(data._x_defs),
                deps = direct,
                gc_goopts = list(data._gc_goopts),
                runfiles = data.runfiles,
                cgo = data._cgo,
                cdeps = list(data._cdeps),
                cppopts = list(data._cppopts),
                copts = list(data._copts),
                cxxopts = list(data._cxxopts),
                clinkopts = list(data._clinkopts),
                pgoprofile = None,
                _mode_info = None,
                _package_metadata = package_metadata,
            )
            cache[key] = _emit_archive(
                go,
                source = source,
                # Dependency archives are declared in the consumer's output
                # package, so include the consumer name to avoid action
                # conflicts between sibling consumers.
                _recompile_suffix = ".mode_recompile_{}_{}".format(
                    go.label.name.replace("/", "_"),
                    len(cache),
                ),
            )

    return [cache.get(_archive_key(archive), archive) for archive in archives]

def emit_archive(go, source = None, _recompile_suffix = "", recompile_internal_deps = None, is_external_pkg = False):
    """See go/toolchains.rst#archive for full documentation."""

    if source == None:
        fail("source is a required parameter")

    direct = _archives_in_mode(go, source.deps)
    if direct != source.deps:
        attrs = structs.to_dict(source)
        attrs["deps"] = direct
        source = GoInfo(**attrs)

    archive = _emit_archive(
        go,
        source = source,
        _recompile_suffix = _recompile_suffix,
        recompile_internal_deps = recompile_internal_deps,
        is_external_pkg = is_external_pkg,
    )
    if go._archive_recompile_cache != None and _recompile_suffix:
        # go_test deliberately recompiles dependencies that transitively import
        # its embedded library. Keep that replacement canonical for subsequent
        # archives instead of restoring an older same-label dependency from the
        # mode-normalization cache.
        go._archive_recompile_cache[_archive_key(archive)] = archive
    return archive

def _emit_archive(go, source, _recompile_suffix = "", recompile_internal_deps = None, is_external_pkg = False):
    testfilter = getattr(source, "testfilter", None)
    pre_ext = ""
    if go.mode.linkmode == LINKMODE_C_ARCHIVE:
        pre_ext = "_"  # avoid collision with go_binary output file with .a extension
    elif testfilter == "exclude":
        pre_ext = ".internal"
    elif testfilter == "only":
        pre_ext = ".external"
    if _recompile_suffix:
        pre_ext += _recompile_suffix
    out_lib = go.declare_file(go, name = source.name, ext = pre_ext + ".a")

    # store export information for compiling dependent packages separately
    out_export = go.declare_file(go, name = source.name, ext = pre_ext + ".x")
    out_cgo_export_h = None  # set if cgo used in c-shared or c-archive mode

    nogo = go.nogo

    # nogo is a FilesToRunProvider and some targets don't have it, some have it but no executable.
    if nogo != None and nogo.executable != None and not "no-nogo" in go._ctx.attr.tags:
        out_facts = go.declare_file(go, name = source.name, ext = pre_ext + ".facts")
        out_diagnostics = go.declare_directory(go, name = source.name, ext = pre_ext + "_nogo")
        if validate_nogo(go):
            out_nogo_validation = go.declare_file(go, name = source.name, ext = pre_ext + ".nogo")
        else:
            out_nogo_validation = None
    else:
        nogo = None
        out_facts = None
        out_diagnostics = None
        out_nogo_validation = None

    direct = source.deps

    files = []
    for a in direct:
        files.append(a.runfiles)
        if a.source.mode != go.mode:
            fail("Archive mode does not match {} is {} expected {}".format(a.data.label, mode_string(a.source.mode), mode_string(go.mode)))
    runfiles = source.runfiles.merge_all(files)

    importmap = "main" if source.is_main else source.importmap
    importpath, _ = effective_importpath_pkgpath(source)

    cgo_out_dir = None
    headers = depset(
        direct = [f for f in source.srcs if f.path.split(".")[-1].lower().startswith("h")],
        transitive = [a._headers for a in direct],
    )

    if source.cgo and not go.mode.pure:
        cgo_out_dir = go.declare_directory(go, path = out_lib.basename + ".cgo")

        # TODO(jayconrod): do we need to do full Bourne tokenization here?
        cppopts = [f for fs in source.cppopts for f in fs.split(" ")]
        copts = [f for fs in source.copts for f in fs.split(" ")]
        cxxopts = [f for fs in source.cxxopts for f in fs.split(" ")]
        clinkopts = [f for fs in source.clinkopts for f in fs.split(" ")]
        cgo = cgo_configure(
            go,
            srcs = source.srcs,
            cdeps = source.cdeps,
            cppopts = cppopts,
            copts = copts,
            cxxopts = cxxopts,
            clinkopts = clinkopts,
        )
        if go.mode.linkmode in (LINKMODE_C_SHARED, LINKMODE_C_ARCHIVE):
            out_cgo_export_h = go.declare_file(go, path = "_cgo_install.h")
        cgo_deps = cgo.deps
        cgo_link_inputs = cgo.link_inputs
        runfiles = runfiles.merge(cgo.runfiles)
        emit_compilepkg(
            go,
            sources = source.srcs,
            cover = source.cover,
            embedsrcs = source.embedsrcs,
            importpath = importpath,
            importmap = importmap,
            archives = direct,
            headers = headers,
            out_lib = out_lib,
            out_export = out_export,
            out_facts = out_facts,
            out_diagnostics = out_diagnostics,
            out_nogo_validation = out_nogo_validation,
            nogo = nogo,
            out_cgo_export_h = out_cgo_export_h,
            gc_goopts = source.gc_goopts,
            cgo = True,
            cgo_inputs = cgo.inputs,
            cgo_out_dir = cgo_out_dir,
            cppopts = cgo.cppopts,
            copts = cgo.copts,
            cxxopts = cgo.cxxopts,
            objcopts = cgo.objcopts,
            objcxxopts = cgo.objcxxopts,
            ldflags = cgo.ldflags,
            testfilter = testfilter,
            is_external_pkg = is_external_pkg,
        )
    else:
        cgo_deps = depset()
        cgo_link_inputs = depset()
        emit_compilepkg(
            go,
            sources = source.srcs,
            cover = source.cover,
            embedsrcs = source.embedsrcs,
            importpath = importpath,
            importmap = importmap,
            archives = direct,
            headers = headers,
            out_lib = out_lib,
            out_export = out_export,
            out_facts = out_facts,
            out_diagnostics = out_diagnostics,
            out_nogo_validation = out_nogo_validation,
            nogo = nogo,
            gc_goopts = source.gc_goopts,
            cgo = False,
            testfilter = testfilter,
            recompile_internal_deps = recompile_internal_deps,
            is_external_pkg = is_external_pkg,
        )

    data = GoArchiveData(
        # TODO(#2578): reconsider the provider API. There's a lot of redundant
        # information here. Some fields are tuples instead of lists or dicts
        # since GoArchiveData is stored in a depset, and no value in a depset
        # may be mutable. For now, new copied fields are private (named with
        # a leading underscore) since they may change in the future.

        # GoInfo fields
        name = source.name,
        label = source.label,
        importpath = source.importpath,
        importmap = source.importmap,
        importpath_aliases = source.importpath_aliases,
        pathtype = source.pathtype,
        srcs = tuple(source.srcs),
        cgo_out_dir = cgo_out_dir,
        _cover = source.cover,
        _embedsrcs = tuple(source.embedsrcs),
        _x_defs = tuple(source.x_defs.items()),
        _gc_goopts = tuple(source.gc_goopts),
        _cgo = source.cgo,
        _cdeps = tuple(source.cdeps),
        _cppopts = tuple(source.cppopts),
        _copts = tuple(source.copts),
        _cxxopts = tuple(source.cxxopts),
        _clinkopts = tuple(source.clinkopts),
        _package_metadata = getattr(source, "_package_metadata", None),

        # Information on dependencies
        _dep_labels = tuple([d.data.label for d in direct]),

        # Information needed by dependents
        file = out_lib,
        export_file = out_export,
        facts_file = out_facts,
        runfiles = source.runfiles,
        _validation_output = out_nogo_validation,
        _nogo_diagnostics = out_diagnostics,
        _cgo_deps = cgo_deps,
        _cgo_link_inputs = cgo_link_inputs,
    )
    x_defs = {}
    for a in direct:
        x_defs.update(a.x_defs)
    x_defs.update(source.x_defs)

    # Ensure that the _cgo_export.h of the current target comes first when cgo_exports is iterated
    # by prepending it and specifying the order explicitly. This is required as the CcInfo attached
    # to the archive only exposes a single header rather than combining all headers.
    cgo_exports_direct = [out_cgo_export_h] if out_cgo_export_h else []
    cgo_exports = depset(direct = cgo_exports_direct, transitive = [a.cgo_exports for a in direct], order = "preorder")
    package_metadata = getattr(data, "_package_metadata", None)
    package_metadata_files = depset(
        direct = [package_metadata] if package_metadata else [],
        transitive = [getattr(a, "_package_metadata_files", depset()) for a in direct],
    )
    return GoArchive(
        source = source,
        data = data,
        direct = direct,
        libs = depset(direct = [out_lib], transitive = [a.libs for a in direct]),
        transitive = depset([data], transitive = [a.transitive for a in direct]),
        x_defs = x_defs,
        cgo_deps = depset(transitive = [cgo_deps] + [a.cgo_deps for a in direct]),
        cgo_link_inputs = depset(transitive = [cgo_link_inputs] + [a.cgo_link_inputs for a in direct]),
        cgo_exports = cgo_exports,
        runfiles = runfiles,
        _headers = headers,
        _package_metadata_files = package_metadata_files,
    )
