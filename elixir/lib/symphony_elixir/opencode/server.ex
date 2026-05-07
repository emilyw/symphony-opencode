defmodule SymphonyElixir.Opencode.Server do
  @moduledoc """
  HTTP client for OpenCode server mode.

  OpenCode runs as a long-lived HTTP server with REST endpoints and SSE event streams.
  Each issue gets its own session within the server.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @type session :: %{
          port: integer(),
          base_url: String.t(),
          session_id: String.t() | nil,
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
  def run_turn(%{base_url: base_url, session_id: session_id} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    message_url = "#{base_url}/session/#{session_id}/message"

    with {:ok, message_response} <- send_message(message_url, prompt, issue),
         {:ok, turn_id} <- extract_turn_id(message_response) do
      session_label = "#{session_id}-#{turn_id}"
      Logger.info("OpenCode session started for #{issue_context(issue)} session_id=#{session_label}")

      emit_message(on_message, :session_started, %{session_id: session_label, turn_id: turn_id}, %{})

      events_url = "#{base_url}/session/#{session_id}/events"

      case stream_events(session, events_url, turn_id, on_message) do
        {:ok, result} ->
          Logger.info("OpenCode session completed for #{issue_context(issue)} session_id=#{session_label}")
          emit_message(on_message, :turn_completed, %{session_id: session_label, turn_id: turn_id}, %{})

          {:ok,
           %{
             result: result,
             session_id: session_id,
             turn_id: turn_id
           }}

        {:error, reason} ->
          Logger.warning("OpenCode session ended with error for #{issue_context(issue)} session_id=#{session_label}: #{inspect(reason)}")
          emit_message(on_message, :turn_ended_with_error, %{session_id: session_label, reason: reason}, %{})
          {:error, reason}
      end
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
    case Req.get(base_url <> "/health") do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, base_url}

      {:ok, _} ->
        {:error, :opencode_server_not_ready}

      {:error, reason} ->
        {:error, {:opencode_connection_failed, inspect(reason)}}
    end
  end

  defp create_session(base_url, workspace) do
    case Req.post(base_url <> "/session", json: %{"cwd" => workspace}) do
      {:ok, %{status: status, body: %{"id" => session_id}}} when status in 200..201 ->
        {:ok, session_id}

      {:ok, %{status: status, body: body}} ->
        {:error, {:opencode_session_create_failed, status, inspect(body)}}

      {:error, reason} ->
        {:error, {:opencode_session_create_failed, inspect(reason)}}
    end
  end

  defp send_message(url, prompt, issue) do
    body = %{"content" => prompt, "title" => "#{issue.identifier}: #{issue.title}"}

    case Req.post(url, json: body) do
      {:ok, %{status: status, body: body}} when status in 200..201 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, inspect(body)}}
      {:error, reason} -> {:error, {:send_message_failed, inspect(reason)}}
    end
  end

  defp extract_turn_id(%{"turnId" => turn_id}), do: {:ok, turn_id}
  defp extract_turn_id(%{"id" => id}), do: {:ok, id}
  defp extract_turn_id(body), do: {:error, {:unexpected_response, inspect(body)}}

  defp stream_events(session, events_url, _turn_id, on_message) do
    case Req.get(events_url,
           headers: [{"Accept", "text/event-stream"}],
           receive_timeout: session.turn_timeout_ms,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        result = parse_and_process_sse(to_string(body), on_message, session.stall_timeout_ms)
        {:ok, result}

      {:ok, %{status: status, body: body}} ->
        {:error, {:sse_stream_failed, status, inspect(body)}}

      {:error, reason} ->
        {:error, {:sse_stream_failed, inspect(reason)}}
    end
  end

  defp parse_and_process_sse(body, on_message, _stall_timeout_ms) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, ":")))
    |> Enum.flat_map(fn line ->
      case String.split(line, ": ", parts: 2) do
        ["data", data] -> [data]
        _ -> []
      end
    end)
    |> process_sse_events(%{}, on_message)
  end

  defp process_sse_events([], acc, _on_message), do: acc

  defp process_sse_events([event | rest], acc, on_message) do
    case Jason.decode(event) do
      {:ok, %{"type" => "done"} = payload} ->
        emit_message(on_message, :notification, %{payload: payload}, %{})
        Map.get(payload, "result", acc)

      {:ok, %{"type" => "error", "message" => msg}} ->
        emit_message(on_message, :turn_ended_with_error, %{reason: msg}, %{})
        {:error, {:opencode_error, msg}}

      {:ok, payload} ->
        emit_message(on_message, :notification, %{payload: payload}, %{})
        process_sse_events(rest, acc, on_message)

      {:error, _} ->
        process_sse_events(rest, acc, on_message)
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
