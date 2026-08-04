# Single entry point for every development task. CI runs these same
# targets, so "green locally" and "green in CI" mean the same thing.
.DEFAULT_GOAL := help
.PHONY: help native bundle-native server app test test-go test-sdk test-app \
        fmt fmt-check vet analyze check clean

SPLITCORE_SO := splitcore/build/out/linux/libsplitcore.so
JNI_LIBS     := splitcore/build/out/android/jniLibs
APP_JNI      := app/android/app/src/main/jniLibs

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

native: $(SPLITCORE_SO) ## Build libsplitcore.so for this Linux host

$(SPLITCORE_SO): $(shell find splitcore -name '*.go' -not -name '*_test.go')
	./splitcore/build/build_linux.sh

bundle-native: ## Copy Android jniLibs into the Flutter runner tree
	./splitcore/build/build_android.sh
	mkdir -p $(APP_JNI)
	cp -r $(JNI_LIBS)/. $(APP_JNI)/
	@echo "Bundled jniLibs into $(APP_JNI)"

server: ## Run the PocketBase server on all interfaces, port 8090
	cd server && go run . serve --http=0.0.0.0:8090

app: native ## Run the Flutter app against a local server
	cd app && flutter run \
		--dart-define=SPLITCORE_LIB_PATH=$(CURDIR)/$(SPLITCORE_SO)

test: test-go test-sdk test-app ## Run every test suite

test-go: ## Go unit tests (splitcore + server) and the FFI ABI smoke test
	cd splitcore && go test ./...
	cd server && go test ./...
	$(MAKE) native
	python3 splitcore/build/smoke_test.py

test-sdk: native ## Dart SDK tests (spawns a real PocketBase server)
	cd splitcore_sdk && dart pub get && dart test

test-app: ## Flutter widget tests
	cd app && flutter pub get && flutter test

fmt: ## Format Go and Dart sources in place
	cd splitcore && gofmt -w .
	cd server && gofmt -w .
	cd splitcore_sdk && dart format --line-length 100 .
	cd app && dart format --line-length 100 .

fmt-check: ## Fail if anything is unformatted
	@out=$$(gofmt -l splitcore server); \
	if [ -n "$$out" ]; then echo "unformatted Go files:"; echo "$$out"; exit 1; fi
	cd splitcore_sdk && dart format --line-length 100 --set-exit-if-changed -o none .
	cd app && dart format --line-length 100 --set-exit-if-changed -o none .

vet: ## go vet both modules
	cd splitcore && go vet ./...
	cd server && go vet ./...

analyze: ## Dart/Flutter static analysis
	cd splitcore_sdk && dart pub get && dart analyze --fatal-infos
	cd app && flutter pub get && flutter analyze --fatal-infos

check: fmt-check vet analyze test ## Everything CI runs, in CI's order

clean: ## Remove build outputs
	rm -rf splitcore/build/out
	cd app && flutter clean
