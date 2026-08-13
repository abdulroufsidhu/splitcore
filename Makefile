# Single entry point for every development task. CI runs these same
# targets, so "green locally" and "green in CI" mean the same thing.
.DEFAULT_GOAL := help
.PHONY: help native bundle-native apk linux windows server app test test-go \
        test-sdk test-app fmt fmt-check vet analyze check clean deploy

# `make app` targets the local server; the app's own default is the deployed
# one. Override for an emulator or device: make app POCKETBASE_URL=http://10.0.2.2:8090
POCKETBASE_URL ?= http://127.0.0.1:8090

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

apk: bundle-native ## Build per-ABI release APKs (one per architecture, ~1/3 the size of a fat APK)
	cd app && flutter build apk --release --split-per-abi \
		--obfuscate --split-debug-info=build/symbols

linux: native ## Build the Linux desktop bundle (app/build/linux/x64/release/bundle)
	cd app && flutter build linux --release

# Windows can't be built from Linux — Flutter needs MSVC on a Windows host.
# Run this from Git Bash there; build_windows.sh picks up the native gcc.
# The DLL is copied next to the .exe because, unlike the Linux runner's
# CMakeLists, the Windows one doesn't install it (CI does the same).
windows: ## Build the Windows desktop bundle (Windows host only)
	./splitcore/build/build_windows.sh
	cd app && flutter build windows --release
	cp splitcore/build/out/windows/splitcore.dll app/build/windows/x64/runner/Release/

server: ## Run the PocketBase server on all interfaces, port 8090
	cd server && go run . serve --http=0.0.0.0:8090

app: native ## Run the Flutter app against a local server
	cd app && flutter run \
		--dart-define=POCKETBASE_URL=$(POCKETBASE_URL) \
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

deploy: ## Back up, build, ship and verify the server on production
	./server/deploy.sh

clean: ## Remove build outputs
	rm -rf splitcore/build/out
	cd app && flutter clean
