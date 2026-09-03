package pure_off_embed

/*
int pure_off_embed_value(void) {
    return 6;
}
*/
import "C"

func cgoValue() int {
	return int(C.pure_off_embed_value())
}
