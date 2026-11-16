module RulesHelper
  FILTER_ICONS = { status: "toggle-right", last_run: "history", action_type: "zap", condition_type: "filter", account: "layers", group: "folder" }.freeze

  # The tabs of the rules filter popover, each as { name:, label:, icon:, items:, selected: }.
  # Each name is also the URL parameter that keeps the filter on a reload.
  # Filters with nothing to choose from are left out, and a value from the
  # URL that is not offered selects "all".
  def rule_filters(list_filter, groups)
    filters = {
      status: [ [ t("rules.filters.status.active"), "active" ], [ t("rules.filters.status.inactive"), "inactive" ] ],
      last_run: [ [ t("rules.filters.last_run.matched_nothing"), "matched-nothing" ], [ t("rules.filters.last_run.changed_nothing"), "changed-nothing" ] ],
      action_type: list_filter.action_type_options,
      condition_type: list_filter.condition_type_options,
      account: list_filter.account_options,
      group: groups.any? ? [ [ t("rules.filters.group.none"), "none" ] ] + groups.map { |group| [ group.name, group.id ] } : []
    }

    filters.filter_map do |name, options|
      next if options.empty?

      items = [ { label: t("rules.filters.#{name}.all"), value: "" } ] + options.map { |label, value| { label: label, value: value.to_s } }
      selected = params[name].to_s
      selected = "" unless items.any? { |item| item[:value] == selected }

      { name: name, label: t("rules.filters.#{name}.label"), icon: FILTER_ICONS.fetch(name), items: items, selected: selected }
    end
  end

  # What a rule's latest run did, as the row's data-rule-last-run value. A
  # pending run (async actions still reporting back) and a failed one have no
  # final modified count, so neither reads as "changed nothing".
  def rule_last_run_state(run)
    return "none" if run.nil?
    return "failed" if run.failed?
    return "pending" if run.pending?
    return "matched-nothing" if run.transactions_queued.zero?

    run.transactions_modified.zero? ? "changed-nothing" : "changed"
  end

  def rule_last_run_summary(run)
    case rule_last_run_state(run)
    when "none" then t("rules.last_run.none")
    when "failed" then t("rules.last_run.failed")
    when "pending" then t("rules.last_run.running", matched: number_with_delimiter(run.transactions_queued))
    else
      t("rules.last_run.summary",
        matched: number_with_delimiter(run.transactions_queued),
        changed: number_with_delimiter(run.transactions_modified),
        date: l(run.executed_at.to_date, format: :short_with_year))
    end
  end
end
