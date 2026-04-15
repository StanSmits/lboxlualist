callbacks.Register("CreateMove", function(cmd)
    local me = entities.GetLocalPlayer()
    if me and me:GetPropEntity("m_hActiveWeapon"):GetPropInt("m_iItemDefinitionIndex") == 752 and me:GetPropFloat("m_flRageMeter") >= 100 then
        cmd.buttons = cmd.buttons | IN_RELOAD
    end
end)