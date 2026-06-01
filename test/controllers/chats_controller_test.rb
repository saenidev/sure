require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)
    sign_in @user
  end

  test "gets index" do
    get chats_url
    assert_response :success
  end

  test "creates chat" do
    assert_difference("Chat.count") do
      post chats_url, params: { chat: { content: "Hello", ai_model: "gpt-4.1" } }
    end

    assert_redirected_to chat_path(Chat.order(created_at: :desc).first, thinking: true)
  end

  test "shows chat" do
    get chat_url(chats(:one))
    assert_response :success
  end

  test "show preloads assistant message tool calls" do
    chat = @user.chats.create!(title: "Tool calls")

    3.times do |idx|
      message = chat.messages.create!(
        type: "AssistantMessage",
        content: "Assistant #{idx}",
        ai_model: "gpt-4.1",
        status: "complete"
      )
      ToolCall::Function.create!(
        message: message,
        provider_id: "call_#{idx}",
        provider_call_id: "call_#{idx}",
        function_name: "lookup_#{idx}",
        function_arguments: {},
        function_result: { ok: true }
      )
    end

    with_env_overrides("AI_DEBUG_MODE" => "true") do
      assert_queries_count(matcher: /FROM "?tool_calls"?/i, max: 1) do
        get chat_url(chat)
      end
    end

    assert_response :success
  end

  test "destroys chat" do
    assert_difference("Chat.count", -1) do
      delete chat_url(chats(:one))
    end

    assert_redirected_to chats_url
  end

  test "should not allow access to other user's chats" do
    other_user = users(:family_member)
    other_chat = Chat.create!(user: other_user, title: "Other User's Chat")

    get chat_url(other_chat)
    assert_response :not_found

    delete chat_url(other_chat)
    assert_response :not_found
  end
end
