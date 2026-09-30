SHELL := /bin/sh
LUA ?= luajit

.PHONY: check service-check plugin-check package

check: service-check plugin-check

service-check:
	npm --prefix service run check
	npm --prefix service test

plugin-check:
	$(LUA) plugin/spec/run.lua

package: check
	sh scripts/package-plugin.sh
