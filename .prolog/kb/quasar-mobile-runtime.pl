% Durable KB: native Quasar ownership at the StarIntel Edge boundary.
% Loader: consult index.pl.

mobile_runtime_fact(process_owned_actor_system,
                    'install-adapter-host owns one managed Sento actor system; Android clients do not supervise a second Kotlin actor registry').
mobile_runtime_fact(closed_actor_catalog,
                    'actor.list advertises only actors compiled into the trusted Edge image; client manifests and entrypoint text are never executable authority').
mobile_runtime_fact(closed_actor_dispatch,
                    'actor.dispatch resolves an advertised actor ID and passes its payload as inert data; unknown IDs fail with actor-unavailable').
mobile_runtime_fact(lifecycle_truth,
                    'runtime.status, runtime.start, runtime.stop, and shutdown-adapter-host report and control the actual process-owned actor system').
mobile_runtime_fact(android_teardown,
                    'starintel_ecl_adapter.c invokes SHUTDOWN-ADAPTER-HOST before cl_shutdown so Sento worker threads stop before ECL teardown').
mobile_runtime_fact(domain_actor_authority,
                    'Edge provides infrastructure execution and runtime.echo as a probe; domain expert actors remain canonical dotfiles expert work and must not be fabricated here').
