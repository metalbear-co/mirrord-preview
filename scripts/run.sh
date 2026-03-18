#!/usr/bin/env bash
#
# run.sh - Entrypoint for the mirrord preview GitHub Action.
#
# Expects the following environment variables (set by action.yml):
#   INPUT_ACTION          - "start" or "stop"
#   INPUT_TARGET          - Kubernetes target path      (start, required)
#   INPUT_NAMESPACE       - Kubernetes namespace        (start, optional)
#   INPUT_MODE            - steal | mirror              (start, default: steal)
#   INPUT_FILTER          - header filter regex         (start, required)
#   INPUT_PORTS           - JSON array of ports         (start, optional)
#   INPUT_TTL_MINS        - int or "infinite"           (start, optional)
#   INPUT_KEY             - session key                 (start: optional, stop: required)
#   INPUT_IMAGE           - container image for preview (start, required)
#   INPUT_EXTRA_CONFIG    - JSON object to merge        (start, optional)
#   MIRRORD_PROGRESS_MODE - should be "json"            (set by action.yml)
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
die() { echo "::error::$*"; exit 1; }

# --------------------------------------------------------------------------- #
# Route to start or stop
# --------------------------------------------------------------------------- #
case "${INPUT_ACTION}" in
	start)
		# ---- Validate required inputs ---------------------------------------- #
		[[ -z "${INPUT_TARGET:-}" ]] && die "input 'target' is required for action=start"
		[[ -z "${INPUT_FILTER:-}" ]] && die "input 'filter' is required for action=start"
		[[ -z "${INPUT_IMAGE:-}" ]] && die "input 'image' is required for action=start"

		# ---- Build mirrord.json ---------------------------------------------- #
		CONFIG_DIR="$(mktemp -d)"
		CONFIG_FILE="${CONFIG_DIR}/mirrord.json"

		# Build base config — always use object notation for target.
		jq -n \
		   --arg target_path "${INPUT_TARGET}" \
		   --arg mode        "${INPUT_MODE:-steal}" \
		   --arg filter      "${INPUT_FILTER}" \
		   --arg image       "${INPUT_IMAGE}" \
		'{
			target: { path: $target_path },
			feature: {
				network: {
					incoming: {
						mode: $mode,
						http_filter: {
							header_filter: $filter
						}
					}
				},
				preview: {
					image: $image
				}
			}
		}' > "${CONFIG_FILE}"

		# Optionally add target.namespace
		if [[ -n "${INPUT_NAMESPACE:-}" ]]; then
			jq --arg ns "${INPUT_NAMESPACE}" \
			   '.target.namespace = $ns' \
			   "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
		fi

		# Optionally add http_filter.ports (expects a JSON array string like "[80, 8080]")
		if [[ -n "${INPUT_PORTS:-}" ]]; then
			jq --argjson ports "${INPUT_PORTS}" \
			   '.feature.network.incoming.http_filter.ports = $ports' \
			   "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
		fi

		# Deep-merge extra_config on top of the generated config.
		# Uses jq's `*` operator for recursive object merge — extra_config wins on conflicts.
		if [[ -n "${INPUT_EXTRA_CONFIG:-}" ]]; then
			jq --argjson extra "${INPUT_EXTRA_CONFIG}" \
			   '. * $extra' \
			   "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
		fi

		# TODO: Add SQS filter field when supported
		# TODO: Add Kafka filter field when supported

		echo "::group::Generated mirrord.json"
		cat "${CONFIG_FILE}"
		echo ""
		echo "::endgroup::"

		# ---- Assemble CLI args ----------------------------------------------- #
		CLI_ARGS=( "mirrord" "preview" "start" "-f" "${CONFIG_FILE}" )

		if [[ -n "${INPUT_TTL_MINS:-}" ]]; then
			CLI_ARGS+=( "--ttl" "${INPUT_TTL_MINS}" )
		fi

		if [[ -n "${INPUT_KEY:-}" ]]; then
			CLI_ARGS+=( "--key" "${INPUT_KEY}" )
		fi

		echo "::group::Running mirrord preview start"
		echo "+ ${CLI_ARGS[*]}"

		# Run and capture output.
		# MIRRORD_PROGRESS_MODE=json makes mirrord emit structured JSON progress.
		OUTPUT=$( "${CLI_ARGS[@]}" 2>&1 ) || {
			echo "${OUTPUT}"
			die "mirrord preview start failed"
		}
		echo "${OUTPUT}"
		echo "::endgroup::"

		# ---- Extract session key from JSON output ---------------------------- #
		# mirrord emits one JSON object per line. The session key appears as:
		#   {"type":"NewTask","name":"key: <value>","parent":"mirrord preview start"}
		# We grab the .name field that starts with "key: " and strip the prefix.
		SESSION_KEY=$(echo "${OUTPUT}" | jq -r '
			select(.name != null)
			| .name
			| select(startswith("key: "))
			| ltrimstr("key: ")
		' 2>/dev/null | head -1 || true)

		if [[ -z "${SESSION_KEY}" ]]; then
			die "Could not extract session key from mirrord output."
		else
			echo "session-key=${SESSION_KEY}" >> "$GITHUB_OUTPUT"
			echo "::notice::Preview session key: ${SESSION_KEY}"
		fi

		# Clean up temp config
		rm -rf "${CONFIG_DIR}"
		;;

	stop)
		# ---- Validate required inputs ---------------------------------------- #
		[[ -z "${INPUT_KEY:-}" ]] && die "input 'key' is required for action=stop"

		echo "::group::Running mirrord preview stop"
		echo "+ mirrord preview stop --key ${INPUT_KEY}"

		mirrord preview stop --key "${INPUT_KEY}" || die "mirrord preview stop failed"

		echo "::endgroup::"
		echo "::notice::Preview session ${INPUT_KEY} stopped."
		;;

	*)
		die "Unknown action '${INPUT_ACTION}'. Must be 'start' or 'stop'."
		;;
esac
