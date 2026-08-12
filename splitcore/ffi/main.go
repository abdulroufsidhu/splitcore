// Command ffi builds splitcore as a C shared library. Every export
// takes a JSON request string and returns a malloc'd JSON response
// string that the caller MUST release via SplitcoreFree.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"unsafe"

	"github.com/abdulroufsidhu/splitcore/splitcore/ffi/handler"
)

// ffiErrJSON marshals an error message the same way handler.errJSON
// does, so a panic value containing quotes or newlines can never
// produce invalid JSON on the C side of the boundary.
func ffiErrJSON(msg string) string {
	b, _ := json.Marshal(map[string]string{"error": msg})
	return string(b)
}

// safeCall is the single crossing point between C and Go for every
// export below: it turns a NULL request pointer or any panic inside fn
// into a JSON error string instead of letting either reach the host
// process, since a crash or unwind across the cgo boundary is undefined
// behavior there.
func safeCall(req *C.char, fn func(string) string) (out string) {
	defer func() {
		if r := recover(); r != nil {
			out = ffiErrJSON(fmt.Sprintf("internal: %v", r))
		}
	}()
	if req == nil {
		return ffiErrJSON("internal: null request")
	}
	return fn(C.GoString(req))
}

//export SplitcoreComputeSplits
func SplitcoreComputeSplits(req *C.char) *C.char {
	return C.CString(safeCall(req, handler.ComputeSplitsJSON))
}

//export SplitcoreSimplifyDebts
func SplitcoreSimplifyDebts(req *C.char) *C.char {
	return C.CString(safeCall(req, handler.SimplifyDebtsJSON))
}

//export SplitcoreComputeBalances
func SplitcoreComputeBalances(req *C.char) *C.char {
	return C.CString(safeCall(req, handler.ComputeBalancesJSON))
}

//export SplitcoreFree
func SplitcoreFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
