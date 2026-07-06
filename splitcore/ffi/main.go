// Command ffi builds splitcore as a C shared library. Every export
// takes a JSON request string and returns a malloc'd JSON response
// string that the caller MUST release via SplitcoreFree.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	"github.com/abdulroufsidhu/slice_pay/splitcore/ffi/handler"
)

//export SplitcoreComputeSplits
func SplitcoreComputeSplits(req *C.char) *C.char {
	return C.CString(handler.ComputeSplitsJSON(C.GoString(req)))
}

//export SplitcoreSimplifyDebts
func SplitcoreSimplifyDebts(req *C.char) *C.char {
	return C.CString(handler.SimplifyDebtsJSON(C.GoString(req)))
}

//export SplitcoreComputeBalances
func SplitcoreComputeBalances(req *C.char) *C.char {
	return C.CString(handler.ComputeBalancesJSON(C.GoString(req)))
}

//export SplitcoreFree
func SplitcoreFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
