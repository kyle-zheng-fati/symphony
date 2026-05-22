defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @townhall_post_tool "townhall_post"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @townhall_post_description """
  Post a town hall event and optionally mirror it to Discord. Use this for human-visible blockers such as missing credentials, missing OPENAI_API_KEY, provider/auth failures, or RAG/search blockers that need Kyle to act. Set transport to local,discord when the human must be pinged; never include secret values.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @townhall_post_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["claim", "next"],
    "properties" => %{
      "level" => %{
        "type" => "string",
        "enum" => ["tele", "mechanism", "submechanism", "state"],
        "description" => "Town hall level. Defaults to state."
      },
      "owner" => %{
        "type" => "string",
        "enum" => ["codex", "claude", "human", "orchestrator"],
        "description" => "Event owner. Defaults to codex."
      },
      "claim" => %{"type" => "string", "description" => "Concise blocker or status claim."},
      "evidence" => %{"type" => "string", "description" => "Exact command, path, or symptom. Do not include secrets."},
      "next" => %{"type" => "string", "description" => "Action the human or next agent should take."},
      "workspace" => %{"type" => "string", "description" => "Workspace path. Defaults to the current process cwd."},
      "branch" => %{"type" => "string", "description" => "Branch or task slug. Defaults to none."},
      "mention" => %{"type" => "string", "description" => "Mention target or none. Defaults to none."},
      "status" => %{"type" => "string", "description" => "Status such as needs-human, blocked, or open."},
      "transport" => %{
        "type" => "string",
        "description" => "local, discord, slack, all, or comma-separated. Defaults to local,discord."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @townhall_post_tool ->
        execute_townhall_post(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @townhall_post_tool,
        "description" => @townhall_post_description,
        "inputSchema" => @townhall_post_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_townhall_post(arguments, opts) do
    runner = Keyword.get(opts, :townhall_runner, &run_townhall_post/1)

    with {:ok, payload} <- normalize_townhall_post_arguments(arguments),
         {:ok, response} <- runner.(payload) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_townhall_post_arguments(arguments) when is_map(arguments) do
    with {:ok, claim} <- normalize_townhall_required(arguments, :claim),
         {:ok, next} <- normalize_townhall_required(arguments, :next) do
      payload = %{
        "level" => normalize_townhall_optional(arguments, :level, "state"),
        "owner" => normalize_townhall_optional(arguments, :owner, "codex"),
        "claim" => claim,
        "evidence" => normalize_townhall_optional(arguments, :evidence, "none"),
        "next" => next,
        "workspace" => normalize_townhall_optional(arguments, :workspace, File.cwd!()),
        "branch" => normalize_townhall_optional(arguments, :branch, "none"),
        "mention" => normalize_townhall_optional(arguments, :mention, "none"),
        "status" => normalize_townhall_optional(arguments, :status, "open"),
        "transport" => normalize_townhall_optional(arguments, :transport, "local,discord")
      }

      {:ok, payload}
    end
  end

  defp normalize_townhall_post_arguments(_arguments), do: {:error, :invalid_townhall_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_townhall_required(arguments, key) when is_atom(key) do
    value = Map.get(arguments, Atom.to_string(key)) || Map.get(arguments, key)

    case normalize_string(value) do
      "" -> {:error, {:missing_townhall_field, Atom.to_string(key)}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_townhall_optional(arguments, key, default) when is_atom(key) do
    value = Map.get(arguments, Atom.to_string(key)) || Map.get(arguments, key)

    case normalize_string(value) do
      "" -> default
      normalized -> normalized
    end
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(nil), do: ""
  defp normalize_string(value), do: value |> to_string() |> String.trim()

  defp run_townhall_post(payload) do
    root = System.get_env("AGENT_HARNESS_ROOT") || Path.expand("~/agent-harness")
    script = Path.join([root, "scripts", "town-hall-mcp.py"])

    case System.cmd("python3", [script, "--call", "townhall.post", "--args", Jason.encode!(payload)],
           stderr_to_stdout: true,
           env: [{"AGENT_HARNESS_ROOT", root}]
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, %{"output" => output}}
        end

      {output, status} ->
        {:error, {:townhall_post_failed, status, output}}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_townhall_arguments) do
    %{
      "error" => %{
        "message" => "`townhall_post` expects an object with at least `claim` and `next` strings."
      }
    }
  end

  defp tool_error_payload({:missing_townhall_field, field}) do
    %{
      "error" => %{
        "message" => "`townhall_post` requires a non-empty `#{field}` string."
      }
    }
  end

  defp tool_error_payload({:townhall_post_failed, status, output}) do
    %{
      "error" => %{
        "message" => "`townhall_post` failed with exit status #{status}.",
        "output" => output
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
