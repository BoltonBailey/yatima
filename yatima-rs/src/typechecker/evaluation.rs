use crate::constant::DefSafety;
use crate::typechecker::{
  expression::*,
  universe::*,
  value::*,
};
use im::Vector;
use std::{
  cell::RefCell,
  rc::Rc,
};

#[inline]
pub fn result(val: Value) -> ThunkPtr { Rc::new(RefCell::new(Thunk::Res(val))) }

#[inline]
pub fn suspend(expr: ExprPtr, env: Env) -> ThunkPtr {
  Rc::new(RefCell::new(Thunk::Sus(expr, env)))
}

#[inline]
pub fn force(thunk: &ThunkPtr) -> Value {
  let borrow = thunk.borrow();
  match &*borrow {
    Thunk::Res(val) => val.clone(),
    Thunk::Sus(expr, env) => {
      let val = eval(expr.clone(), env.clone());
      drop(borrow);
      let mut mut_borrow = thunk.borrow_mut();
      *mut_borrow = Thunk::Res(val.clone());
      val
    }
  }
}

pub fn eval(expr: ExprPtr, mut env: Env) -> Value {
  match &*expr {
    Expr::Var(idx) => force(&env.exprs[*idx]),
    Expr::Sort(lvl) => {
      // Value::Sort only takes fully reduced levels, so we instantiate all
      // variables using the universe environment and reduce
      let lvl = inst_bulk_reduce(lvl, &env.univs);
      Value::Sort(lvl)
    }
    Expr::Const(cnst, cnst_univs) => {
      let univs = cnst_univs
        .iter()
        .map(|lvl| inst_bulk_reduce(lvl, &env.univs))
        .collect();
      eval_const(cnst, univs)
    }
    Expr::App(fun, arg) => {
      let arg = suspend(arg.clone(), env.clone());
      let fun = eval(fun.clone(), env.clone());
      match fun {
        Value::Lam(_, body, lam_env) => {
          let mut lam_env = lam_env.clone();
          lam_env.exprs.push_front(arg);
          eval(body.clone(), lam_env)
        }
        Value::App(var @ Neutral::FVar(..), args) => {
          let mut args = args.clone();
          args.push_front(arg);
          Value::App(var, args)
        }
        Value::App(Neutral::Const(cnst, cnst_univs), args) => {
          let univs = cnst_univs
            .iter()
            .map(|lvl| inst_bulk_reduce(lvl, &env.univs))
            .collect();
          apply_const(cnst, univs, arg, args)
        }
        _ => unreachable!(),
      }
    }
    Expr::Lam(binfo, _, body) => Value::Lam(*binfo, body.clone(), env),
    Expr::Pi(binfo, dom, cod) => {
      let dom = suspend(dom.clone(), env.clone());
      Value::Pi(*binfo, dom, cod.clone(), env)
    }
    Expr::Let(_, expr, body) => {
      env.exprs.push_front(suspend(expr.clone(), env.clone()));
      eval(body.clone(), env)
    }
    Expr::Lit(lit) => Value::Lit(lit.clone()),
    Expr::Lty(lty) => Value::Lty(*lty),
    Expr::Fix(body) => {
      let body = body.clone();
      let itself = suspend(expr, env.clone());
      env.exprs.push_front(itself);
      eval(body, env)
    },
    _ => todo!() // Projections
  }
}

#[inline]
pub fn eval_const(cnst: &ConstPtr, univs: Vector<UnivPtr>) -> Value {
  match &**cnst {
    Const::Theorem { expr, .. }
    | Const::Definition { safe: DefSafety::Safe, expr, .. } => {
      eval(expr.clone(), Env { exprs: Vector::new(), univs })
    }
    Const::Definition { safe: DefSafety::Unsafe, .. } => {
      panic!("Cannot use unsafe definitions inside types")
    }
    _ => Value::App(Neutral::Const(cnst.clone(), univs), Vector::new()),
  }
}

#[inline]
pub fn apply_const(
  cnst: ConstPtr,
  univs: Vector<UnivPtr>,
  arg: ThunkPtr,
  mut args: Vector<ThunkPtr>,
) -> Value {
  // Assumes a partial application of k to args, which means in particular, that
  // it is in normal form
  match &*cnst {
    Const::Recursor { params, motives, minors, indices, rules, .. } => {
      let major_idx = params + motives + minors + indices;
      if args.len() != major_idx {
        args.push_front(arg);
        return Value::App(Neutral::Const(cnst, univs), args);
      }
      match force(&arg) {
        Value::App(Neutral::Const(ctor, _), ctor_args) => {
          match &*ctor {
            Const::Constructor { .. } => {
              // Since we assume expressions are previously type checked, we
              // know that this constructor must have an
              // associated recursion rule
              let rule = rules.get(&Rc::as_ptr(&ctor)).unwrap();
              // Indices are not needed used at all in recursion rules
              args.slice(indices..);
              // The number of parameters in the constructor is not necessarily
              // equal to the number of parameters in the recursor in nested
              // inductive types, but the rule knows how many arguments to take
              let mut exprs = ctor_args.take(rule.nfields);
              exprs.append(args);
              return eval(rule.rhs.clone(), Env { exprs, univs });
            }
            _ => (),
          }
        }
        _ => (),
      }
    }
    Const::Quotient { .. } => {
      todo!()
    }
    _ => (),
  }
  args.push_front(arg);
  Value::App(Neutral::Const(cnst, univs), args)
}

#[cfg(test)]
pub mod tests {
  use crate::parse::utils::{
    BindCtx,
    GlobalCtx,
    UnivCtx,
  };

  use crate::parse::{
    expr::parse_expr_apps,
    span::Span,
    error::ParseError,
  };

  use crate::expression::Expr as YExpr;
  use crate::environment::Env as YEnv;

  use im::{
    OrdMap,
    Vector,
  };

  use crate::typechecker::from_anon::{expr_from_anon, ConversionEnv};

  use super::*;

  fn read_back_neutral(neu : Neutral) -> Expr {
    match neu {
      Neutral::FVar(idx) => Expr::Var(idx),
      Neutral::Const(cnst, univs) => Expr::Const(cnst, univs.iter().map(|lvl| lvl.clone()).collect())
    }
  }

  fn shift_env(env : Env) -> Env {
    Env {
      exprs: env.exprs.iter().map(|expr| {
        match &*expr.borrow() {
          Thunk::Res(Value::App(Neutral::FVar(idx), args)) => 
            Rc::new(RefCell::new(Thunk::Res(
              Value::App(Neutral::FVar(idx + 1), args.clone())
            ))),
          _ => expr.clone(),
        }
      }).collect(),
      univs : env.univs
    }
  }

  pub fn read_back(val : Value) -> Expr {
    match val {
      Value::Sort(univ) => Expr::Sort(univ),
      Value::App(neu, args) => {
        args.iter().rev().fold(read_back_neutral(neu),
          |acc, arg|
            Expr::App(
              Rc::new(acc),
              Rc::new(read_back(force(arg)))
            )
        )
      }
      Value::Lam(bin, body, env) => {
        // any neutral fvars in the environment are now additionally nested,
        // and so must have their de bruijn indices incremented
        let mut lam_env = shift_env(env);
        // add a new free variable for this lambda's argument
        let arg = Rc::new(RefCell::new(Thunk::Res(Value::App(Neutral::FVar(0), Vector::new()))));
        lam_env.exprs.push_front(arg);
        // binder types are irrelevant to reduction and so are lost on evaluation;
        // arbitrarily fill these in with `Sort 0`
        Expr::Lam(bin, Rc::new(Expr::Sort(Rc::new(Univ::Zero))), Rc::new(read_back(eval(body, lam_env))))
      },
      Value::Pi(bin, dom, cod, env) => {
        let mut pi_env = shift_env(env);
        let arg = Rc::new(RefCell::new(Thunk::Res(Value::App(Neutral::FVar(0), Vector::new()))));
        pi_env.exprs.push_front(arg);
        Expr::Pi(bin, Rc::new(read_back(force(&dom))), Rc::new(read_back(eval(cod, pi_env))))
      },
      Value::Lit(lit) => todo!(),
      Value::Lty(lty) => todo!(),
    }
  }

  pub fn to_expr(i: &str, env : Rc<RefCell<YEnv>>) -> ExprPtr {
    let yexpr : YExpr = parse_expr_apps(Vector::new(), Vector::new(), OrdMap::new(), env.clone()) (Span::new(i),).unwrap().1;
    let myenv = &mut *env.borrow_mut();
    let yexpr = &yexpr.store(myenv).unwrap().anon;
    expr_from_anon(yexpr, myenv, &mut ConversionEnv::new())
  }

  // Test equivalence of of the reduction of `inp` and the expected reduction `red`
  // w.r.t. their anonymous expressions.
  fn check_reduce(inp: &str, red: &str) {
    let env = Rc::new(RefCell::new(YEnv::new()));
    let act = read_back(eval(to_expr(inp, env.clone()), Env::new()));
    let exp = to_expr(red, env.clone());

    println!("Actual reduction:\t{:?}\nExpected reduction:\t{:?}", act, exp);
    assert!(act == *exp);
  }

  fn check_read_back(inp: &str) {
    check_reduce(inp, inp);
  }

  #[test]
  fn test_read_back() {
    check_read_back("Π (x : Prop) (y : Prop) → x");
    check_read_back("λ (x : Prop) (y : Prop) => x");
    check_read_back("λ (x : Prop) (y : Prop) => Π (a : Prop) (b : Prop) → a b x y");
    check_read_back("λ (f : Prop) (x : Prop) => f x");
  }

  #[test]
  fn test_lam() {
    check_reduce("λ (a: Prop) => a", "λ (a: Prop) => a");
  }

  #[test]
  fn test_app_lam() {
    check_reduce("(λ (a: Sort 1) => a) Prop", "Prop");
    check_reduce("(λ (a: Sort 1) (b: Sort 2) => a) Prop (Sort 1)", "Prop");
    check_reduce("(λ (a: Sort 1) (b: Sort 2) => b) Prop (Sort 1)", "Sort 1");
  }
}
