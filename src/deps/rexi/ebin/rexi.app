{application,rexi,
             [{description,"Lightweight RPC server"},
              {vsn,"1.5.3"},
              {registered,[rexi_sup,rexi_server]},
              {applications,[kernel,stdlib]},
              {mod,{rexi_app,[]}},
              {modules,[rexi,rexi_app,rexi_monitor,rexi_server,rexi_sup,
                        rexi_utils]}]}.
