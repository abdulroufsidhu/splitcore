#!/usr/bin/env python3
"""Smoke test for libsplitcore.so — proves the C ABI works end to end."""
import ctypes
import json
import os
import sys

so_path = os.path.join(os.path.dirname(__file__), "out", "linux", "libsplitcore.so")
lib = ctypes.CDLL(so_path)

for fn in ("SplitcoreComputeSplits", "SplitcoreSimplifyDebts", "SplitcoreComputeBalances"):
    getattr(lib, fn).argtypes = [ctypes.c_char_p]
    getattr(lib, fn).restype = ctypes.c_void_p  # keep pointer for Free
lib.SplitcoreFree.argtypes = [ctypes.c_void_p]


def call(fn, req: dict) -> dict:
    ptr = getattr(lib, fn)(json.dumps(req).encode())
    try:
        return json.loads(ctypes.string_at(ptr).decode())
    finally:
        lib.SplitcoreFree(ptr)


splits = call("SplitcoreComputeSplits", {
    "type": "equal", "total_cents": 10000,
    "entries": [{"member_id": m} for m in ("a", "b", "c")],
})
assert splits == {"splits": [
    {"member_id": "a", "amount_cents": 3334},
    {"member_id": "b", "amount_cents": 3333},
    {"member_id": "c", "amount_cents": 3333},
]}, splits

transfers = call("SplitcoreSimplifyDebts", {
    "balances": [{"member_id": "a", "net_cents": 500},
                 {"member_id": "b", "net_cents": -500}],
})
assert transfers == {"transfers": [
    {"from_member_id": "b", "to_member_id": "a", "amount_cents": 500},
]}, transfers

balances = call("SplitcoreComputeBalances", {
    "expenses": [{"payer_id": "a", "amount_cents": 1000,
                  "splits": [{"member_id": "b", "amount_cents": 1000}]}],
    "settlements": [{"from_member_id": "b", "to_member_id": "a", "amount_cents": 400}],
})
assert balances == {"balances": [
    {"member_id": "a", "net_cents": 600},
    {"member_id": "b", "net_cents": -600},
]}, balances

err = call("SplitcoreComputeSplits", {"type": "magic", "total_cents": 1, "entries": []})
assert "error" in err, err

print("smoke test OK")
