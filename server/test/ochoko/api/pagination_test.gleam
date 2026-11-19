import gleam/http
import gleam/option.{None, Some}
import ochoko/api/pagination.{Page}
import wisp/simulate

pub fn pagination_parse_limits_test() {
  let page = pagination.parse(simulate.request(http.Get, "/x?limit=100"))
  assert page.limit == 40
  let page = pagination.parse(simulate.request(http.Get, "/x"))
  assert page == Page(None, None, None, 20)
  let page =
    pagination.parse(simulate.request(http.Get, "/x?max_id=5&min_id=2&limit=0"))
  assert page == Page(Some(5), None, Some(2), 1)
}

pub fn link_header_test() {
  assert pagination.link_header("https://h/a", Some(9), Some(3))
    == Some(
      "<https://h/a?max_id=3>; rel=\"next\", <https://h/a?min_id=9>; rel=\"prev\"",
    )
  assert pagination.link_header("https://h/a", None, None) == None
  assert pagination.link_header("https://h/a?x=1", Some(9), Some(3))
    == Some(
      "<https://h/a?x=1&max_id=3>; rel=\"next\", <https://h/a?x=1&min_id=9>; rel=\"prev\"",
    )
}
