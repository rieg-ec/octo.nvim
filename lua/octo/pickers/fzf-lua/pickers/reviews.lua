local fzf = require "fzf-lua"

return function(reviews_list, on_select)
  local formatted_reviews = {}
  local titles = {}

  for _, review in ipairs(reviews_list) do
    local author = review.author and review.author.login or "ghost"
    local title = string.format("%s  %-20s %3d", review.display_date or review.createdAt, author, review.comment_count or 0)
    formatted_reviews[title] = review
    table.insert(titles, title)
  end

  fzf.fzf_exec(titles, {
    prompt = nil,
    fzf_opts = {
      ["--no-multi"] = "",
    },
    actions = {
      ["default"] = function(selected)
        local review = formatted_reviews[selected[1]]
        if review then
          on_select(review)
        end
      end,
    },
  })
end
