require 'test_helper'

class DmailsControllerTest < ActionDispatch::IntegrationTest
  context "The dmails controller" do
    setup do
      @user = create(:user, unread_dmail_count: 1)
      @unrelated_user = create(:user)
      as_user do
        @dmail = create(:dmail, :owner => @user)
      end
    end

    teardown do
      CurrentUser.user = nil
      CurrentUser.ip_addr = nil
    end

    context "new action" do
      should "get the page" do
        get_auth new_dmail_path, @user
        assert_response :success
      end

      context "with a respond_to_id" do
        should "check privileges" do
          @user2 = create(:user)
          get_auth new_dmail_path, @user2, params: {:respond_to_id => @dmail.id}
          assert_response 403
        end

        should "prefill the fields" do
          get_auth new_dmail_path, @user, params: {:respond_to_id => @dmail.id}
          assert_response :success
        end

        context "and a forward flag" do
          should "not populate the to field" do
            get_auth new_dmail_path, @user, params: {:respond_to_id => @dmail.id, :forward => true}
            assert_response :success
          end
        end
      end
    end

    context "index action" do
      should "show dmails owned by the current user by sent" do
        get_auth dmails_path, @user, params: {:search => {:owner_id => @dmail.owner_id, :folder => "sent"}}
        assert_response :success
      end

      should "show dmails owned by the current user by received" do
        get_auth dmails_path, @user, params: {:search => {:owner_id => @dmail.owner_id, :folder => "received"}}
        assert_response :success
      end

      should "not show dmails not owned by the current user" do
        get_auth dmails_path, @user, params: {:search => {:owner_id => @dmail.owner_id}}
        assert_response :success
      end

      should "work for banned users" do
        as(create(:admin_user)) do
          create(:ban, :user => @user)
        end
        get_auth dmails_path, @dmail.owner, params: {:search => {:owner_id => @dmail.owner_id, :folder => "sent"}}

        assert_response :success
      end
    end

    context "show action" do
      should "show dmails owned by the current user" do
        get_auth dmail_path(@dmail), @dmail.owner
        assert_response :success
      end

      should "not show dmails not owned by the current user" do
        get_auth dmail_path(@dmail), @unrelated_user
        assert_response(403)
      end

      should "show dmails not owned by the current user when given a valid key" do
        get_auth dmail_path(@dmail, key: @dmail.key), @unrelated_user
        assert_response :success
      end

      should "not show dmails not owned by the current user when given an invalid key" do
        get_auth dmail_path(@dmail, key: @dmail.key + "blah"), @unrelated_user
        assert_response 403
      end

      should "mark dmails as read" do
        assert_equal(false, @dmail.is_read)
        get_auth dmail_path(@dmail), @dmail.owner

        assert_response :success
        assert_equal(true, @dmail.reload.is_read)
      end

      should "not mark dmails as read in the api" do
        assert_equal(false, @dmail.is_read)
        get_auth dmail_path(@dmail, format: :json), @dmail.owner

        assert_response :success
        assert_equal(false, @dmail.reload.is_read)
      end

      should "not mark dmails as read when viewing dmails owned by another user" do
        assert_equal(false, @dmail.is_read)
        get_auth dmail_path(@dmail, key: @dmail.key), @unrelated_user

        assert_response :success
        assert_equal(false, @dmail.reload.is_read)
      end
    end

    context "create action" do
      setup do
        @user_2 = create(:user)
      end

      should "create two messages, one for the sender and one for the recipient" do
        assert_difference("Dmail.count", 2) do
          dmail_attribs = {:to_id => @user_2.id, :title => "abc", :body => "abc"}
          post_auth dmails_path, @user, params: {:dmail => dmail_attribs}
          assert_redirected_to dmail_path(Dmail.last)
        end
      end
    end

    context "update action" do
      should "allow deletion if the dmail is owned by the current user" do
        put_auth dmail_path(@dmail), @user, params: { dmail: { is_deleted: true } }

        assert_redirected_to dmail_path(@dmail)
        assert_equal(true, @dmail.reload.is_deleted)
      end

      should "not allow deletion if the dmail is not owned by the current user" do
        put_auth dmail_path(@dmail), @unrelated_user, params: { dmail: { is_deleted: true } }

        assert_response 403
        assert_equal(false, @dmail.reload.is_deleted)
      end

      should "not allow updating if the dmail is not owned by the current user even with a dmail key" do
        put_auth dmail_path(@dmail), @unrelated_user, params: { dmail: { is_deleted: true }, key: @dmail.key }

        assert_response 403
        assert_equal(false, @dmail.reload.is_deleted)
      end

      should "update user's unread_dmail_count when marking dmails as read or unread" do
        put_auth dmail_path(@dmail), @user, params: { dmail: { is_read: true } }
        assert_equal(true, @dmail.reload.is_read)
        assert_equal(0, @user.reload.unread_dmail_count)

        put_auth dmail_path(@dmail), @user, params: { dmail: { is_read: false } }
        assert_equal(false, @dmail.reload.is_read)
        assert_equal(1, @user.reload.unread_dmail_count)
      end
    end

    context "mark all as read action" do
      setup do
        @sender = create(:user)
        @recipient = create(:user)

        as(@sender) do
          @dmail1 = Dmail.create_split(title: "test1", body: "test", to: @recipient)
          @dmail2 = Dmail.create_split(title: "test2", body: "test", to: @recipient)
          @dmail3 = Dmail.create_split(title: "test3", body: "test", to: @recipient, is_read: true)
          @dmail4 = Dmail.create_split(title: "test4", body: "test", to: @recipient, is_deleted: true)
        end
      end

      should "mark all unread, undeleted dmails as read" do
        assert_equal(4, @recipient.dmails.count)
        assert_equal(2, @recipient.dmails.active.unread.count)
        assert_equal(2, @recipient.reload.unread_dmail_count)
        post_auth mark_all_as_read_dmails_path(format: :js), @recipient

        assert_response :success
        assert_equal(0, @recipient.reload.unread_dmail_count)
        assert_equal(true, [@dmail1, @dmail2, @dmail3, @dmail4].all?(&:is_read))
      end
    end

    context "when a user has unread dmails" do
      should "show the unread dmail notice" do
        get_auth posts_path, @user

        assert_response :success
        assert_select "#dmail-notice", 1
        assert_select "#nav-my-account-link", text: "My Account (1)"
      end
    end
  end
end
