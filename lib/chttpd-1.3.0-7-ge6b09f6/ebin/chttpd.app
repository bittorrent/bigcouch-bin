{application,chttpd,
             [{description,"HTTP interface for CouchDB cluster"},
              {vsn,"1.3.0-7-ge6b09f6"},
              {registered,[chttpd_sup,chttpd]},
              {applications,[kernel,stdlib,couch,fabric]},
              {mod,{chttpd_app,[]}},
              {modules,[chttpd,chttpd_app,chttpd_db,chttpd_external,
                        chttpd_misc,chttpd_rewrite,chttpd_show,chttpd_sup,
                        chttpd_view]}]}.
