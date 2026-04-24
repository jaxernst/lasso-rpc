defmodule LassoWeb.Plugs.SocialCrawlerPreviewPlug do
  @moduledoc false

  import Plug.Conn

  @crawler_signatures [
    "facebookexternalhit",
    "facebot",
    "twitterbot",
    "slackbot-linkexpanding",
    "discordbot",
    "linkedinbot",
    "whatsapp",
    "telegrambot",
    "skypeuripreview",
    "googlebot"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    user_agent = conn |> get_req_header("user-agent") |> List.first("")

    if crawler_user_agent?(user_agent) do
      put_session(conn, :allow_unauthenticated_preview, true)
    else
      delete_session(conn, :allow_unauthenticated_preview)
    end
  end

  defp crawler_user_agent?(user_agent) do
    downcased = String.downcase(user_agent)
    Enum.any?(@crawler_signatures, &String.contains?(downcased, &1))
  end
end
