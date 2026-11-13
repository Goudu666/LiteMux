.PHONY: app run test clean

app:
	./scripts/bundle.sh

run: app
	open build/LiteMux.app

test:
	swift test

clean:
	rm -rf .build build
