defmodule SymphonyElixir.Opencode.Server do
  @moduledoc """
  HTTP client for OpenCode server mode.

  OpenCode runs as a long-lived HTTP server. Each issue gets its own session.
  Messages are sent synchronously — the POST /session/:id/message response
  contains the full assistant reply in a `parts` array (no SSE needed).
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
    message_url = "#{base_url}/session/#{session_id}/message"

    with {:ok, response} <- send_message(message_url, prompt, turn_timeout_ms),
         {:ok, turn_id} <- extract_turn_id(response) do
      session_label = "#{session_id}-#{turn_id}"
      Logger.info("OpenCode turn completed for #{issue_context(issue)} session_id=#{session_label}")

      emit_message(on_message, :turn_completed, %{session_id: session_label, turn_id: turn_id, payload: response}, %{})

      {:ok,
       %{
         result: response,
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

  defp send_message(url, prompt, timeout_ms) do
    body = %{"parts" => [%{"type" => "text", "text" => prompt}]}

    case Req.post(url, json: body, receive_timeout: timeout_ms) do
      {:ok, %{status: status, body: body}} when status in 200..201 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, inspect(body)}}
      {:error, reason} -> {:error, {:send_message_failed, inspect(reason)}}
    end
  end

  defp extract_turn_id(%{"info" => %{"id" => turn_id}}), do: {:ok, turn_id}
  defp extract_turn_id(%{"id" => id}), do: {:ok, id}
  defp extract_turn_id(body), do: {:error, {:unexpected_response, inspect(body)}}

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
