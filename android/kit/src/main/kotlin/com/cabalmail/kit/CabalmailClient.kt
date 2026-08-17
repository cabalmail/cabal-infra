package com.cabalmail.kit

import com.cabalmail.kit.config.ConfigService

/**
 * Entry point the app layer holds onto. Will own the Cognito auth session
 * (Phase 3) and expose the Lambda API surface (`listFolders`,
 * `listEnvelopes`, `fetchMessage`, ...) the way the Apple
 * `CabalmailClient` does. For now it only carries the config service.
 */
class CabalmailClient(
    val configService: ConfigService,
)
