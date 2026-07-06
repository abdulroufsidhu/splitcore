package main

import (
	"log"
	"os"
	"strings"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"

	"github.com/abdulroufsidhu/slice_pay/server/hooks"
	_ "github.com/abdulroufsidhu/slice_pay/server/migrations"
)

func main() {
	app := pocketbase.New()

	// enable `migrate` subcommand; automigrate applies pending
	// migrations on serve in dev
	isGoRun := strings.HasPrefix(os.Args[0], os.TempDir())
	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{
		Automigrate: isGoRun,
	})

	hooks.Register(app)

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}
