#!/usr/bin/env bash
#
# run.sh — Entrypoint for the mirrord preview GitHub Action.
#
# Expects the following environment variables (set by action.yml):
#   INPUT_ACTION    — "start" or "stop"
#   INPUT_TARGET    — Kubernetes target path        (start, required)
#   INPUT_MODE      — steal | mirror                (start, default: steal)
#   INPUT_FILTER    — header filter regex            (start, required)
#   INPUT_PORTS     — JSON array of ports            (start, optional)
#   INPUT_TTL_MINS  — int or "infinite"              (start, optional)
#   INPUT_KEY       — session key                    (start: optional, stop: required)
#   MIRRORD_PROGRESS_MODE — should be "json" (set by action.yml)
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

		# ---- Build mirrord.json ---------------------------------------------- #
		CONFIG_DIR="$(mktemp -d)"
		CONFIG_FILE="${CONFIG_DIR}/mirrord.json"

		# Start with the base config object using jq
		jq -n \
		   --arg target "${INPUT_TARGET}" \
		   --arg mode   "${INPUT_MODE:-steal}" \
		   --arg filter "${INPUT_FILTER}" \
		   '{
      target: $target,
      feature: {
        network: {
          incoming: {
            mode: $mode,
            http_filter: {
              header_filter: $filter
            }
          }
        }
      }
    }' > "${CONFIG_FILE}"

		# Optionally add http_filter.ports (expects a JSON array string like "[80, 8080]")
		if [[ -n "${INPUT_PORTS:-}" ]]; then
			jq --argjson ports "${INPUT_PORTS}" \
			   '.feature.network.incoming.http_filter.ports = $ports' \
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
		# TODO: Replace the jq expression below with the actual extraction logic
		#       once the mirrord preview JSON output format is confirmed.
		#       The JSON progress output (MIRRORD_PROGRESS_MODE=json) should
		#       contain the session key. Pipe $OUTPUT through jq to extract it.
		#
		# Example placeholder — adjust the jq filter to match real output:
		SESSION_KEY=$(echo "${OUTPUT}" | jq -r '
      # TODO: write the real jq filter here.
      # Placeholder: try to find a "key" or "session_key" field in any JSON line.
      select(.key != null) | .key // empty
    ' 2>/dev/null | tail -1 || true)

		if [[ -z "${SESSION_KEY}" ]]; then
			echo "::warning::Could not extract session key from mirrord output. You may need to update the jq extraction logic."
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
