-- AIEditMetadata.lua
-- Defines a hidden plugin metadata field used to stash each photo's
-- develop settings BEFORE an AI edit, so we can revert later.

return {
    metadataFieldsForPhotos = {
        {
            id        = "preEditSettings",
            -- Not shown in the Metadata panel; used internally for revert.
            dataType  = "string",
            browsable = false,
        },
    },
    schemaVersion = 1,
}
