# detect the build OS
ifeq ($(OS),Windows_NT)
	build_OS := Windows
	NUL = NUL
else
	build_OS := $(shell uname -s 2>/dev/null || echo Unknown)
	NUL = /dev/null
endif

CARVEL_REQUIRED_BINARIES := imgpkg kbld ytt vendir kapp
REQUIRED_BINARIES := helm clusterctl kubectl yq

.DEFAULT_GOAL:=help

### GLOBAL ###
WORKING_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
ROOT_DIR := $(shell git rev-parse --show-toplevel)

help: ## Display this help message
	# Platform-Ops Repository
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[0-9A-Za-z_-]+:.*?##/ { printf "  \033[36m%-45s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##### OPERATIONS #####

check-carvel: ## Check to make sure you have the requried carvel tools
	$(foreach exec,$(CARVEL_REQUIRED_BINARIES),\
		$(if $(shell which $(exec)),,$(error "'$(exec)' not found. Carvel toolset is required. See instructions at https://carvel.dev/#install")))

check: check-carvel ## Check to make sure you have the right tools
	$(foreach exec,$(REQUIRED_BINARIES),\
		$(if $(shell which $(exec)),,$(error "'$(exec)' not found. $(exec) is required. See instructions at https://github.com/Jeremy-Boyle/asi-project.git")))
