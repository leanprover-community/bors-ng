defmodule BorsNG.Worker.Zulip do
  @moduledoc """
  A helper module containing code for sending notifications to Zulip,
  as configured by the environment variables:

  - ZULIP_API_URL
  - ZULIP_BOT_EMAIL
  - ZULIP_BOT_API_KEY
  - ZULIP_CHANNEL_NAME
  - ZULIP_TOPIC
  """
  require Logger

  def send_message(message) do
    if Application.get_env(:bors, :is_test) do
      :ok
    else
      try do
        zulip_api_url = Confex.fetch_env!(:bors, :zulip_api_url)
        bot_email = Confex.fetch_env!(:bors, :zulip_bot_email)
        bot_api_key = Confex.fetch_env!(:bors, :zulip_bot_api_key)
        channel_name = Confex.fetch_env!(:bors, :zulip_channel_name)
        topic = Confex.fetch_env!(:bors, :zulip_topic)

        # Skip if any required config is empty
        if empty_string?(zulip_api_url) or empty_string?(bot_email) or empty_string?(bot_api_key) or
             empty_string?(channel_name) or empty_string?(topic) do
          Logger.info("Missing Zulip config. Zulip notification was not sent.")
          :ok
        else
          body = %{
            "type" => "channel",
            "to" => channel_name,
            "topic" => topic,
            "content" => message
          }

          client =
            Tesla.client(
              [
                {Tesla.Middleware.BasicAuth, username: bot_email, password: bot_api_key},
                Tesla.Middleware.FormUrlencoded
              ],
              Tesla.Adapter.Hackney
            )

          Tesla.post(client, zulip_api_url <> "messages", body)
        end
      rescue
        e ->
          Logger.error("Failed to send Zulip message: #{message}\n\nerror: #{inspect(e)}")
          :error
      end
    end
  end

  defp empty_string?(""), do: true
  defp empty_string?(_), do: false
end
