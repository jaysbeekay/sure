# Records that belong to a family other than the signed-in user's, for tests
# that must show a request cannot attach them.
module ForeignFamilyTestHelper
  private
    def foreign_family
      @foreign_family ||= Family.create!(name: "Foreign Family", currency: "USD")
    end

    def foreign_category
      @foreign_category ||= foreign_family.categories.create!(name: "Foreign category", color: "#4da568", lucide_icon: "shapes")
    end

    def foreign_merchant
      @foreign_merchant ||= foreign_family.merchants.create!(name: "Foreign merchant")
    end

    def foreign_tag
      @foreign_tag ||= foreign_family.tags.create!(name: "Foreign tag")
    end
end
