%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1999-2009. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%
{application, runtime_tools,
   [{description,  "RUNTIME_TOOLS version 1"},
    {vsn,          "1.8.2"},
    {modules,      [dbg,observer_backend,percept_profile,
		    inviso_rt,inviso_rt_lib,inviso_rt_meta,
		    inviso_as_lib,inviso_autostart,inviso_autostart_server,
		    runtime_tools,runtime_tools_sup,erts_alloc_config]},
    {registered,   [runtime_tools_sup,inviso_rt,inviso_rt_meta]},
    {applications, [kernel, stdlib]},
%    {env,          [{inviso_autostart_mod,your_own_autostart_module}]},
    {env,          []},
    {mod,          {runtime_tools, []}}]}.


