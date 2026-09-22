module AccountAuthorizable
  extend ActiveSupport::Concern

  included do
    include StreamExtensions
  end

  # Which permissions satisfy which level. One table, because a view that has
  # to decide whether to RENDER a control needs the same answer the action uses
  # to ACCEPT it, and a second copy of the list is how the two drift: the
  # control disappears for someone whose save would have succeeded, or is
  # offered to someone whose save is refused. Read through #account_permission?
  # rather than copied.
  PERMISSION_LEVELS = {
    write: %i[owner full_control],
    annotate: %i[owner full_control read_write],
    owner: %i[owner]
  }.freeze

  private

    # Does the current user clear `level` on this account? An unknown level
    # clears nothing, which is the `else false` the case statement had.
    def account_permission?(account, level)
      PERMISSION_LEVELS.fetch(level, []).include?(account.permission_for(Current.user))
    end

    def require_account_permission!(account, level = :write, redirect_path: nil)
      return true if account_permission?(account, level)

      path = redirect_path || account_path(account)
      respond_to do |format|
        format.html { redirect_back_or_to path, alert: t("accounts.not_authorized") }
        format.turbo_stream { stream_redirect_back_or_to(path, alert: t("accounts.not_authorized")) }
        format.json { render json: { error: t("accounts.not_authorized") }, status: :forbidden }
      end
      false
    end
end
