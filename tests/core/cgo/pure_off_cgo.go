package pure_off

/*
int pure_off_value(void) {
    return 40;
}
*/
import "C"

func Value() int {
	return int(C.pure_off_value())
}
