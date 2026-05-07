defmodule SymphonyElixir.Opencode.Server do
  @moduledoc """
  HTTP client for OpenCode server mode.

  OpenCode runs as a long-lived HTTP server. Each issue gets its own session.
  Messages are sent via POST /session/:id/message, which returns immediately
  with an empty body. Turn completion is detected by subscribing to the SSE
  event stream at /event and waiting for session.status: idle.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @type session :: %{
          port: integer(),
          base_url: String.t(),
          session_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          turn_timeout_ms: integer(),
          stall_timeout_ms: integer()
        }

  @type turn_result :: %{
          result: map(),
          session_id: String.t(),
          turn_id: String.t()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    {:ok, settings} = Config.opencode_runtime_settings()
    port = settings.port
    turn_timeout_ms = settings.turn_timeout_ms
    stall_timeout_ms = settings.stall_timeout_ms

    with {:ok, validated_workspace} <- validate_workspace(workspace, worker_host),
         {:ok, server_url} <- check_server_ready("http://localhost:#{port}"),
         {:ok, session_id} <- create_session(server_url, validated_workspace) do
      {:ok,
       %{
         port: port,
         base_url: server_url,
         session_id: session_id,
         workspace: validated_workspace,
         worker_host: worker_host,
         turn_timeout_ms: turn_timeout_ms,
         stall_timeout_ms: stall_timeout_ms
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, turn_result()} | {:error, term()}
  def run_turn(%{base_url: base_url, session_id: session_id, turn_timeout_ms: turn_timeout_ms} = _session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    messages_url = "#{base_url}/session/#{session_id}/message"
    event_url = "#{base_url}/event"

    with {:ok, known_ids} <- get_message_ids(messages_url),
         {:ok, turn_id} <- post_and_wait_for_idle(event_url, messages_url, session_id, known_ids, prompt, turn_timeout_ms) do
      session_label = "#{session_id}-#{turn_id}"
      Logger.info("OpenCode turn completed for #{issue_context(issue)} session_id=#{session_label}")

      emit_message(on_message, :turn_completed, %{session_id: session_label, turn_id: turn_id, payload: %{}}, %{})

      {:ok,
       %{
         result: %{},
         session_id: session_id,
         turn_id: turn_id
       }}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{base_url: base_url, session_id: session_id}) do
    Req.delete("#{base_url}/session/#{session_id}")
    :ok
  rescue
    _ -> :ok
  end

  defp validate_workspace(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp check_server_ready(base_url) do
    case Req.get(base_url <> "/session") do
      {:ok, %{status: 200}} ->
        {:ok, base_url}

      {:ok, _} ->
        {:error, :opencode_server_not_ready}

      {:error, reason} ->
        {:error, {:opencode_connection_failed, inspect(reason)}}
    end
  end

  defp create_session(base_url, workspace) do
    title = Path.basename(workspace)

    case Req.post(base_url <> "/session", json: %{"title" => title}) do
      {:ok, %{status: status, body: %{"id" => session_id}}} when status in 200..201 ->
        {:ok, session_id}

      {:ok, %{status: status, body: body}} ->
        {:error, {:opencode_session_create_failed, status, inspect(body)}}

      {:error, reason} ->
        {:error, {:opencode_session_create_failed, inspect(reason)}}
    end
  end

  defp get_message_ids(messages_url) do
    case Req.get(messages_url) do
      {:ok, %{status: 200, body: msgs}} when is_list(msgs) ->
        ids = MapSet.new(msgs, fn m -> get_in(m, ["info", "id"]) end)
        {:ok, ids}

      {:ok, _} ->
        {:ok, MapSet.new()}

      {:error, reason} ->
        {:error, {:get_messages_failed, inspect(reason)}}
    end
  end

  # The POST /session/:id/message endpoint streams its response body while the LLM
  # generates tokens, so Req.post blocks for the entire turn duration. We start
  # the SSE listener concurrently before posting so we never miss the idle event.
  defp post_and_wait_for_idle(event_url, messages_url, session_id, known_ids, prompt, timeout_ms) do
    caller = self()
    ref = make_ref()
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    sse_task =
      Task.async(fn ->
        result =
          Req.get(event_url,
            receive_timeout: timeout_ms + 120_000,
            into: fn chunk, buffer ->
              if System.monotonic_time(:millisecond) > deadline_ms do
                {:halt, buffer}
              else
                full = buffer <> chunk
                {events, rest} = extract_sse_events(full)

                idle =
                  Enum.any?(events, fn
                    %{
                      "type" => "session.status",
                      "properties" => %{
                        "sessionID" => ^session_id,
                        "status" => %{"type" => "idle"}
                      }
                    } ->
                      true

                    _ ->
                      false
                  end)

                if idle do
                  send(caller, {ref, :idle})
                  {:halt, rest}
                else
                  {:cont, rest}
                end
              end
            end
          )

        case result do
          {:ok, _} -> send(caller, {ref, :sse_ended})
          {:error, reason} -> send(caller, {ref, {:sse_error, reason}})
        end
      end)

    post_task =
      Task.async(fn ->
        body = %{"parts" => [%{"type" => "text", "text" => prompt}]}

        case Req.post(messages_url, json: body, receive_timeout: timeout_ms + 120_000) do
          {:ok, %{status: status}} when status in 200..201 ->
            send(caller, {ref, :post_ok})

          {:ok, %{status: status, body: body}} ->
            send(caller, {ref, {:post_error, {:http_error, status, inspect(body)}}})

          {:error, reason} ->
            send(caller, {ref, {:post_error, {:send_message_failed, inspect(reason)}}})
        end
      end)

    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    result =
      receive do
        {^ref, :idle} ->
          :completed

        {^ref, :post_ok} ->
          :completed

        {^ref, :sse_ended} ->
          {:error, :sse_stream_ended_without_idle}

        {^ref, {:sse_error, reason}} ->
          {:error, {:sse_error, inspect(reason)}}

        {^ref, {:post_error, reason}} ->
          {:error, reason}
      after
        max(remaining_ms, 0) ->
          {:error, :turn_timeout}
      end

    Task.shutdown(sse_task, :brutal_kill)
    Task.shutdown(post_task, :brutal_kill)

    case result do
      :completed -> get_last_turn_id(messages_url, known_ids)
      error -> error
    end
  end

  defp extract_sse_events(buffer) do
    parts = String.split(buffer, "\n\n")

    case parts do
      [] ->
        {[], ""}

      [_single] ->
        {[], buffer}

      multiple ->
        complete = Enum.slice(multiple, 0..-2//1)
        remainder = List.last(multiple)

        events =
          complete
          |> Enum.flat_map(fn event_block ->
            event_block
            |> String.split("\n")
            |> Enum.filter(&String.starts_with?(&1, "data: "))
            |> Enum.map(fn line ->
              json_str = String.trim_leading(line, "data: ")

              case Jason.decode(json_str) do
                {:ok, event} -> event
                _ -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)
          end)

        {events, remainder}
    end
  end

  defp get_last_turn_id(messages_url, known_ids) do
    case Req.get(messages_url) do
      {:ok, %{status: 200, body: msgs}} when is_list(msgs) ->
        new_completed_assistant =
          msgs
          |> Enum.filter(fn m ->
            info = m["info"]
            msg_id = info["id"]
            not MapSet.member?(known_ids, msg_id) &&
              info["role"] == "assistant" &&
              get_in(info, ["time", "completed"]) != nil
          end)
          |> List.last()

        case new_completed_assistant do
          nil ->
            {:error, {:unexpected_response, "no new completed assistant message found after turn"}}

          msg ->
            {:ok, get_in(msg, ["info", "id"])}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, inspect(body)}}

      {:error, reason} ->
        {:error, {:get_messages_failed, inspect(reason)}}
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp emit_message(_on_message, _event, _details, _metadata), do: :ok

  defp default_on_message(_message), do: :ok

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
