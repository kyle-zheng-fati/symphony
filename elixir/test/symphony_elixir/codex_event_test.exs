defmodule SymphonyElixir.CodexEventTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Event

  test "normalizes nested live token_count payload usage" do
    payload = %{
      "method" => "codex/event/token_count",
      "params" => %{
        "msg" => %{
          "type" => "event_msg",
          "payload" => %{
            "type" => "token_count",
            "info" => %{
              "total_token_usage" => %{
                "input_tokens" => "250000",
                "output_tokens" => 75_001,
                "total_tokens" => 325_001
              }
            }
          }
        }
      }
    }

    usage = Event.token_usage(payload)
    assert Event.input_tokens(usage) == 250_000
    assert Event.output_tokens(usage) == 75_001
    assert Event.total_tokens(usage) == 325_001
    assert Event.reported_token_total(payload) == 325_001
  end

  test "normalizes thread token usage updates with map or scalar total" do
    map_payload = %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{
        "tokenUsage" => %{
          "total" => %{"inputTokens" => 8, "outputTokens" => 3, "totalTokens" => 11}
        }
      }
    }

    scalar_payload = %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{"tokenUsage" => %{"total" => 42}}
    }

    usage = Event.token_usage(map_payload)
    assert Event.input_tokens(usage) == 8
    assert Event.output_tokens(usage) == 3
    assert Event.total_tokens(usage) == 11
    assert Event.reported_token_total(scalar_payload) == 42
  end

  test "normalizes command output deltas only for guarded stream methods" do
    assert Event.command_output_delta(%{
             "method" => "item/commandExecution/outputDelta",
             "params" => %{"msg" => %{"payload" => %{"outputDelta" => "abc"}}}
           }) == "abc"

    assert Event.command_output_delta(%{
             "method" => "item/agentMessage/delta",
             "params" => %{"delta" => "not guarded"}
           }) == nil
  end

  test "normalizes wrapped guard payloads and command events" do
    update = %{
      event: :turn_guard_failed,
      payload: %{
        payload: %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "tokenUsage" => %{
              "total" => %{"input_tokens" => 316_266, "output_tokens" => 1_401, "total_tokens" => 317_667}
            }
          }
        },
        reason: {:codex_token_budget_exceeded, 317_667, 300_000}
      }
    }

    usage = Event.token_usage_from_update(update)
    assert Event.input_tokens(usage) == 316_266
    assert Event.output_tokens(usage) == 1_401
    assert Event.total_tokens(usage) == 317_667

    command_payload = %{
      "method" => "codex/event/exec_command_begin",
      "params" => %{"msg" => %{"command" => "find . -type f"}}
    }

    assert Event.command_event?(command_payload)
    assert Event.command(command_payload) == "find . -type f"
  end
end
