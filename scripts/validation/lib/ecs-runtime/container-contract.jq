# Canonicalize only documented ECS representations (see ecs-runtime-design.md).
# Keep unknown fields: adding a runtime capability must not silently pass.
.cpu = (if .cpu == null then 0 else .cpu end)
| .readonlyRootFilesystem = (if .readonlyRootFilesystem == null then false else .readonlyRootFilesystem end)
| .memory = .memory
| .memoryReservation = .memoryReservation
| .command = .command
| .entryPoint = .entryPoint
| .startTimeout = .startTimeout
| .stopTimeout = .stopTimeout
| .healthCheck = (
    if .healthCheck == null then null
    else .healthCheck | .startPeriod = (if .startPeriod == null then 0 else .startPeriod end)
    end
  )
| .dependsOn = ((.dependsOn // []) | sort_by(.containerName, .condition))
| .mountPoints = ((.mountPoints // []) | sort_by(.sourceVolume, .containerPath))
| .portMappings = ((.portMappings // []) | sort_by(.containerPort, .protocol))
| .secrets = ((.secrets // []) | sort_by(.name))
| .environment_hashes = ((.environment_hashes // []) | sort_by(.name))
| .volumesFrom = (.volumesFrom // [])
| .systemControls = (.systemControls // [])
| .logConfiguration.secretOptions = (.logConfiguration.secretOptions // [])
