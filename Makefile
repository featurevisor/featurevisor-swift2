.PHONY: build test clean setup-monorepo update-monorepo setup-golang-sdk update-golang-sdk setup-references update-references

build:
	swift build

test:
	swift test

clean:
	swift package clean

setup-monorepo:
	mkdir -p monorepo
	if [ ! -d "monorepo/.git" ]; then \
		git clone git@github.com:featurevisor/featurevisor.git monorepo; \
	else \
		(cd monorepo && git fetch origin main && git checkout main && git pull origin main); \
	fi
	(cd monorepo && make install && make build)

update-monorepo:
	(cd monorepo && git pull origin main && make install && make build)

setup-golang-sdk:
	mkdir -p featurevisor-go
	if [ ! -d "featurevisor-go/.git" ]; then \
		git clone git@github.com:featurevisor/featurevisor-go.git featurevisor-go; \
	else \
		(cd featurevisor-go && git fetch origin main && git checkout main && git pull origin main); \
	fi

update-golang-sdk:
	(cd featurevisor-go && git pull origin main)

setup-references:
	make setup-monorepo
	make setup-golang-sdk

update-references:
	make update-monorepo
	make update-golang-sdk
