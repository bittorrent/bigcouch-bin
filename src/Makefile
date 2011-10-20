# Copyright 2010 Cloudant
# 
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
# 
#   http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

all:  compile

appfile = apps/couch/ebin/couch.app
compile:
	@echo "==> couchjs (compile)"
	@cd couchjs && python scons/scons.py
	@./rebar compile
	@cat $(appfile) | sed s/%VSN%/`git describe --match 1.*`/ > $(appfile)

clean:
	@echo "==> couchjs (clean)"
	@cd couchjs && python scons/scons.py --clean
	@./rebar clean

# compile is required here because of cross-dependencies between apps
check: compile
	@./rebar eunit
	@ERL_FLAGS="-pa `pwd`/apps/couch/ebin" prove apps/couch/test/etap/*.t

dist: compile
	@rm -rf rel/bigcouch
	@./rebar generate

distclean: clean
	@rm -rf rel/bigcouch

include install.mk
install: dist
	@mkdir -p $(prefix)
	@cp -R rel/bigcouch/* $(prefix)
	@mkdir -p $(data_dir)
	@chown $(user) $(data_dir)
	@mkdir -p $(view_dir)
	@chown $(user) $(view_dir)
	@touch $(prefix)/var/log/bigcouch.log
	@chown $(user) $(prefix)/var/log/bigcouch.log

dev: compile
	@rm -rf rel/dev1 rel/dev2 rel/dev3
	@echo "==> Building development node #1 (ports 15984/15986)"
	@./rebar generate target_dir=dev1 overlay_vars=dev1.config
	@echo "==> Building development node #2 (ports 25984/25986)"
	@./rebar generate target_dir=dev2 overlay_vars=dev2.config
	@echo "==> Building development node #3 (ports 35984/35986)"
	@./rebar generate target_dir=dev3 overlay_vars=dev3.config
	@echo "\n\
Development nodes are built, and can be started using ./rel/dev[123]/bin/bigcouch.\n\
Once the nodes are started, they must be joined together by editing the local\n\
nodes DB. For example, executing\n\
\n\
    curl localhost:15986/nodes/dev2@127.0.0.1 -X PUT -d '{}'\n\
    curl localhost:15986/nodes/dev3@127.0.0.1 -X PUT -d '{}'\n\
\n\
will cause node 1 to immediately connect to nodes 2 and 3 and form a cluster.\n\
The content of the nodes database is continuously replicated throughout the\n\
cluster, so this is a one-time operation.\n"
