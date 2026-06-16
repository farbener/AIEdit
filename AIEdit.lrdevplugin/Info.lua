return {
    LrSdkVersion        = 6.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = "io.github.farbener.aiedit",
    LrPluginName        = "AI Edit",

    LrMetadataProvider  = "AIEditMetadata.lua",

    LrLibraryMenuItems = {
        {
            title  = "AI Edit Selected Photo...",
            file   = "AIEditDialog.lua",
        },
        {
            title  = "AI Edit: Revert to Original",
            file   = "AIEditRevert.lua",
        },
    },

    LrExportMenuItems = nil,

    VERSION = { major = 1, minor = 5, revision = 0 },
}
