require "test_helper"

class LoansControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
  end

  test "creates with loan details" do
    assert_difference -> { Account.count } => 1,
      -> { Loan.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post loans_path, params: {
        account: {
          name: "New Loan",
          balance: 50000,
          currency: "USD",
          institution_name: "Local Bank",
          institution_domain: "localbank.example",
          notes: "Mortgage notes",
          accountable_type: "Loan",
          accountable_attributes: {
            subtype: "mortgage",
            interest_rate: 5.5,
            term_months: 60,
            rate_type: "fixed",
            initial_balance: 50000
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Loan", created_account.name
    assert_equal 50000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Local Bank", created_account[:institution_name]
    assert_equal "localbank.example", created_account[:institution_domain]
    assert_equal "Mortgage notes", created_account[:notes]
    assert_equal "mortgage", created_account.accountable.subtype
    assert_equal 5.5, created_account.accountable.interest_rate
    assert_equal 60, created_account.accountable.term_months
    assert_equal "fixed", created_account.accountable.rate_type
    assert_equal 50000, created_account.accountable.initial_balance

    assert_redirected_to created_account
    assert_equal "Loan account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "create with invalid original principal does not create loan" do
    assert_no_difference [ "Account.count", "Loan.count", "Valuation.count", "Entry.count" ] do
      post loans_path, params: {
        account: {
          name: "Bad Loan",
          balance: 50000,
          currency: "USD",
          accountable_type: "Loan",
          accountable_attributes: {
            subtype: "student",
            initial_balance: "not-a-number"
          }
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "create with invalid current balance does not create loan" do
    assert_no_difference [ "Account.count", "Loan.count", "Valuation.count", "Entry.count" ] do
      post loans_path, params: {
        account: {
          name: "Bad Loan",
          balance: "not-a-number",
          currency: "USD",
          accountable_type: "Loan",
          accountable_attributes: {
            subtype: "student",
            initial_balance: 50000
          }
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "create with blank original principal uses current balance for opening anchor" do
    post loans_path, params: {
      account: {
        name: "Blank Principal Loan",
        balance: 48000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: {
          subtype: "student",
          initial_balance: ""
        }
      }
    }

    created_account = Account.order(:created_at).last
    opening_anchor = created_account.valuations.opening_anchor.includes(:entry).first

    assert_redirected_to created_account
    assert_nil created_account.loan.initial_balance
    assert_equal BigDecimal("48000"), opening_anchor.entry.amount
    assert_equal BigDecimal("48000"), created_account.loan.original_balance.amount
  end

  test "updates with loan details" do
    assert_no_difference [ "Account.count", "Loan.count" ] do
      patch loan_path(@account), params: {
        account: {
          name: "Updated Loan",
          balance: 45000,
          currency: "USD",
          institution_name: "Updated Bank",
          institution_domain: "updatedbank.example",
          notes: "Updated loan notes",
          accountable_type: "Loan",
          accountable_attributes: {
            id: @account.accountable_id,
            subtype: "auto",
            interest_rate: 4.5,
            term_months: 48,
            rate_type: "fixed",
            initial_balance: 48000
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Loan", @account.name
    assert_equal 45000, @account.balance
    assert_equal "Updated Bank", @account[:institution_name]
    assert_equal "updatedbank.example", @account[:institution_domain]
    assert_equal "Updated loan notes", @account[:notes]
    assert_equal "auto", @account.accountable.subtype
    assert_equal 4.5, @account.accountable.interest_rate
    assert_equal 48, @account.accountable.term_months
    assert_equal "fixed", @account.accountable.rate_type
    assert_equal 48000, @account.accountable.initial_balance

    assert_redirected_to @account
    assert_equal "Loan account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates original principal from initial balance on existing manual loan" do
    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        balance: 45000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id,
          initial_balance: 48000
        }
      }
    }

    @account.reload

    opening_anchor = @account.valuations.opening_anchor.includes(:entry).first
    current_update = @account.valuations.reconciliation.includes(:entry).find { |valuation| valuation.entry.date == Date.current }

    assert_equal BigDecimal("48000"), opening_anchor.entry.amount
    assert_equal BigDecimal("48000"), @account.loan.original_balance.amount
    assert_equal BigDecimal("45000"), current_update.entry.amount
    assert_equal BigDecimal("45000"), @account.balance
  end

  test "invalid original principal does not update opening anchor" do
    @account.set_opening_anchor_balance(balance: 50000.to_d)

    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        balance: @account.balance,
        currency: @account.currency,
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id,
          initial_balance: "not-a-number"
        }
      }
    }

    assert_response :unprocessable_entity
    assert_equal 50000.to_d, @account.reload.opening_anchor_balance
  end

  test "non-finite original principal does not update opening anchor" do
    @account.set_opening_anchor_balance(balance: 50000.to_d)

    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        balance: @account.balance,
        currency: @account.currency,
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id,
          initial_balance: "NaN"
        }
      }
    }

    assert_response :unprocessable_entity
    assert_equal 50000.to_d, @account.reload.opening_anchor_balance
  end

  test "invalid current balance does not update loan balance" do
    original_balance = @account.balance

    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        balance: "not-a-number",
        currency: @account.currency,
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id
        }
      }
    }

    assert_response :unprocessable_entity
    assert_equal original_balance, @account.reload.balance
  end

  test "non-finite current balance does not update loan balance" do
    original_balance = @account.balance

    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        balance: "NaN",
        currency: @account.currency,
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id
        }
      }
    }

    assert_response :unprocessable_entity
    assert_equal original_balance, @account.reload.balance
  end

  test "current balance manager failure renders error" do
    Account.any_instance.stubs(:set_current_balance).returns(
      Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "forced balance failure")
    )

    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        balance: @account.balance + 1,
        currency: @account.currency,
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id
        }
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "forced balance failure"
  end
end
