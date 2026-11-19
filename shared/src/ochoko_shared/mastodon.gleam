pub type Visibility {
  Public
  Unlisted
  Private
  Direct
}

pub fn visibility_to_string(v: Visibility) -> String {
  case v {
    Public -> "public"
    Unlisted -> "unlisted"
    Private -> "private"
    Direct -> "direct"
  }
}
