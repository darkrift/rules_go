package pure_off_second_cgo

/*
int pure_off_second_value(void) {
    return 4;
}
*/
import "C"

func Value() int {
	return int(C.pure_off_second_value())
}
