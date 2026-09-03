class LoanAmortizationSchedulesController < ApplicationController
  before_action :set_account
  before_action :authorize_manage!, only: :create

  def index
    @loan = @account.loan
    @schedules = @loan.amortization_schedules.order(:payment_number).page(params[:page])
  end

  def create
    @loan = @account.loan

    if @loan.term_months.nil? || @loan.interest_rate.nil?
      redirect_to @account, alert: t(".missing_loan_details")
      return
    end

    start_date = parsed_start_date
    if start_date == :invalid
      redirect_to @account, alert: t(".invalid_start_date")
      return
    end

    @loan.generate_amortization_schedule(start_date: start_date || Date.today)
    redirect_to @account, notice: t(".schedule_generated")
  end

  private

    def parsed_start_date
      return nil if params[:start_date].blank?

      Date.iso8601(params[:start_date])
    rescue ArgumentError, TypeError
      :invalid
    end

    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
    end

    def authorize_manage!
      permission = @account.permission_for(Current.user)
      redirect_to @account, alert: t("accounts.not_authorized") unless permission.in?([ :owner, :full_control ])
    end
end
