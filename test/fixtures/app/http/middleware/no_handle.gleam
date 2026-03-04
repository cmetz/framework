//// Test fixture for middleware validation tests - missing handle function

pub fn something_else(ctx, next) {
  next(ctx)
}
