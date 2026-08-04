package hooks

import (
	"fmt"
	"net/http"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/security"
)

// registerAccountDeletion binds POST /api/splitcore/delete-account, which
// closes the caller's own account.
//
// It is a route rather than a plain delete rule because "delete my account"
// cannot always mean "delete the row". Every relation pointing at
// group_members — expenses.payer, split_entries.member,
// settlements.from_member/to_member, balances.member — is Required with
// CascadeDelete=false (see migrations/1751760000_init_collections.go), and
// group_members.user points at users the same way. So for anyone who has
// ever appeared in an expense:
//
//   - deleting the users row is refused, because a membership references it;
//   - deleting that membership is refused, because split entries reference it;
//   - deleting those split entries would rewrite *other* members' balances
//     and erase shared history that is not this user's to destroy.
//
// Hence two outcomes:
//
//   - "deleted" — no ledger history at all: memberships are removed and the
//     user row is erased.
//   - "anonymized" — has history: the membership rows stay so balances and
//     history remain correct, and the identity is stripped from the users
//     row (tombstone email, no name, no avatar, unverified, unusable
//     password).
//
// Both paths refuse while any of the user's memberships carries a non-zero
// balance: leaving with money owed silently shifts the debt onto everyone
// else in the group.
func registerAccountDeletion(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.POST("/api/splitcore/delete-account", func(e *core.RequestEvent) error {
			if e.Auth == nil {
				return e.UnauthorizedError("auth required", nil)
			}
			userID := e.Auth.Id

			memberships, err := e.App.FindRecordsByFilter("group_members",
				"user = {:u}", "", 0, 0, dbx.Params{"u": userID})
			if err != nil {
				return err
			}

			for _, m := range memberships {
				net, err := memberNetCents(e.App, m)
				if err != nil {
					return err
				}
				if net != 0 {
					return e.BadRequestError(
						"settle all outstanding balances before deleting your account", nil)
				}
			}

			hasHistory, err := memberHasLedgerHistory(e.App, userID, memberships)
			if err != nil {
				return err
			}

			if hasHistory {
				if err := anonymizeUser(e.App, userID); err != nil {
					return err
				}
				return e.JSON(http.StatusOK, map[string]string{"status": "anonymized"})
			}

			// No history: the memberships and the user row can go. One
			// transaction so a failure cannot leave the user ejected from
			// their groups but still holding an account.
			err = e.App.RunInTransaction(func(txApp core.App) error {
				for _, m := range memberships {
					if err := txApp.Delete(m); err != nil {
						return err
					}
				}
				user, err := txApp.FindRecordById("users", userID)
				if err != nil {
					return err
				}
				return txApp.Delete(user)
			})
			if err != nil {
				return err
			}
			return e.JSON(http.StatusOK, map[string]string{"status": "deleted"})
		})
		return se.Next()
	})
}

// memberNetCents reads the cached balance for one group_members row. A
// missing row means the group has no balances yet, which is a zero net.
func memberNetCents(app core.App, member *core.Record) (int64, error) {
	bal, err := app.FindFirstRecordByFilter("balances",
		"group = {:g} && member = {:m}",
		dbx.Params{"g": member.GetString("group"), "m": member.Id})
	if err != nil {
		// No balances row for this member — nothing owed either way.
		return 0, nil
	}
	return int64(bal.GetInt("net_cents")), nil
}

// memberHasLedgerHistory reports whether this user is referenced anywhere
// that makes erasure impossible or destructive: as the owner of a group,
// or by an expense, split entry, or settlement.
//
// Group ownership counts because groups.owner is a required, non-cascading
// relation to users — the row physically cannot be deleted while a group
// points at it, and deleting the group instead would take every other
// member's history with it.
func memberHasLedgerHistory(app core.App, userID string, memberships []*core.Record) (bool, error) {
	owned, err := app.FindRecordsByFilter("groups", "owner = {:u}", "", 1, 0,
		dbx.Params{"u": userID})
	if err != nil {
		return false, err
	}
	if len(owned) > 0 {
		return true, nil
	}

	for _, m := range memberships {
		checks := []struct {
			collection string
			filter     string
		}{
			{"expenses", "payer = {:m}"},
			{"split_entries", "member = {:m}"},
			{"settlements", "from_member = {:m} || to_member = {:m}"},
		}
		for _, c := range checks {
			rows, err := app.FindRecordsByFilter(c.collection, c.filter, "", 1, 0,
				dbx.Params{"m": m.Id})
			if err != nil {
				return false, err
			}
			if len(rows) > 0 {
				return true, nil
			}
		}
	}
	return false, nil
}

// anonymizeUser strips every piece of identity from a users row while
// leaving the row itself in place, so the group_members rows that point at
// it — and therefore every balance and expense — stay valid.
func anonymizeUser(app core.App, userID string) error {
	user, err := app.FindRecordById("users", userID)
	if err != nil {
		return err
	}

	// The email must stay unique and must not be the real one. The random
	// suffix also means a second deleted account cannot collide.
	user.Set("email", fmt.Sprintf("deleted-%s@invalid.splitcore", security.RandomString(12)))
	user.Set("name", "")
	user.Set("avatar", "")
	user.Set("verified", false)
	user.Set("emailVisibility", false)
	// A random password nobody holds: the account cannot be signed into
	// again, and the row is not left with the old credentials.
	user.SetPassword(security.RandomString(40))
	user.SetTokenKey(security.RandomString(50))

	return app.Save(user)
}
