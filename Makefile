ifneq (,$(wildcard ./.env))
    include .env
    export
endif

cmd-exists-%:
	@hash $(*) > /dev/null 2>&1 || \
		(echo "ERROR: '$(*)' must be installed and available on your PATH."; exit 1)


.PHONY: check_valid_key
check_valid_key:
	@if echo "${PRIVATE_KEY}" | grep -Eq '^[0-9a-fA-F]{64}$$'; then \
		echo "Valid private key"; \
	else \
		echo "Invalid private key"; \
		exit 1; \
	fi

.PHONY: init fmt build clean rebuild test test-gas trace remappings
init: cmd-exists-forge
	git submodule update --init --recursive
	git update-index --assume-unchanged playground/*
	forge install

fmt: cmd-exists-forge
	forge fmt

build: cmd-exists-forge
	forge build

clean: cmd-exists-forge
	forge clean

rebuild: clean build

test: cmd-exists-forge
	forge test --match-path "test/unit/*"

test-gas: cmd-exists-forge
	forge test -vv --gas-report

trace: cmd-exists-forge
	forge test -vvvv

remappings: cmd-exists-forge
	forge remappings > remappings.txt

.PHONY: fork 
fork: cmd-exists-anvil
	anvil --fork-url ${ETHEREUM_RPC} --fork-block-number ${BLOCK_NUMBER_MAINNET}

.PHONY: deploy
deploy: cmd-exists-forge
	./script/sh/deploy.sh
