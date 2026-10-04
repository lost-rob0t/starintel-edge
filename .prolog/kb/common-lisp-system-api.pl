% Durable KB: Attax-OS Common Lisp system API and distro boundaries.

system_api_platform(debian).
system_api_platform(nixos).
system_api_platform(termux).

system_api_invariant(default_deny,
                     'Every installed capability rechecks an injected authorizer immediately before its effect; no authorizer means denied').
system_api_invariant(exact_argv,
                     'Catalog tools receive a bounded list of argument strings through UIOP run-program; shell command strings are not accepted').
system_api_invariant(capability_honesty,
                     'Missing GPS, USB, Android relay, Wi-Fi, Bluetooth, Hackmode, or actor-service providers remain unavailable and are not advertised').
system_api_invariant(starintel_authority,
                     'Create and edit submit complete canonical documents through the pinned ingest boundary; Edge owns no dtype registry or patch language').

system_api_owner(edge, capability_dispatch_and_authorization).
system_api_owner(hackmode, recon_providers_and_operation_state).
system_api_owner(star_lang, starintel_schema_and_generated_bindings).

actor_service_invariant(sento_single_owner,
                        'Named actor services run in the process-owned Edge Sento actor system; the system API adapter does not create another supervisor').
actor_service_invariant(live_status,
                        'Service status reconciles its recorded state with the root Sento actor running state').
actor_service_invariant(restart_state,
                        'Stopping the actor system preserves installed service definitions but resets every runtime handle and state to stopped').

distro_shell(attax_os, lish, package_pin_pending).
distro_component_status(hackmode, adapter_present_package_pin_pending).
distro_component_status(actor_services, runtime_adapter_present_os_service_runners_pending).

nix_fact(android_runtime_closure,
         'The Android Lisp asset bundle must include actor-services.lisp plus system-package.lisp and system-api.lisp because starintel-edge/runtime depends on starintel-edge/system-api').
