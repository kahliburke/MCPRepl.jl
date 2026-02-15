const PREF_BRIDGE_MIRROR_REPL = "bridge_mirror_repl"

"""
    get_bridge_mirror_repl_preference() -> Bool

Return whether bridged evaluations should mirror command/result text in the host REPL.
"""
function get_bridge_mirror_repl_preference()
    val = @load_preference(PREF_BRIDGE_MIRROR_REPL, false)
    return val === true
end

"""
    set_bridge_mirror_repl_preference!(enabled::Bool) -> Bool

Persist host-REPL mirroring preference in LocalPreferences.toml.
"""
function set_bridge_mirror_repl_preference!(enabled::Bool)
    @set_preferences!(PREF_BRIDGE_MIRROR_REPL => enabled)
    return enabled
end
