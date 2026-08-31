class LoanAmortizationSchedulesController < ApplicationController
  before_action :set_account
  before_action :authorize_account!

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

    @loan.generate_amortization_schedule(start_date: params[:start_date].present? ? Date.parse(params[:start_date]) : Date.today)
    redirect_to @account, notice: t(".schedule_generated")
  end

  private

  def set_account
    @account = Account.find(params[:account_id])
  end

  def authorize_account!
    redirect_to root_path, status: :unauthorized unless current_user.can_manage?(@account)
  end
end
