package safetyChecker;

import java.util.HashSet;

import com.microsoft.z3.ArithExpr;
import com.microsoft.z3.Expr;
import com.microsoft.z3.InterpolationContext;

import soot.SootMethod;
import soot.Value;
import soot.jimple.InvokeExpr;

public class Z3JavaMathHandler {

	private int arg0Index = 0;
	private int arg1Index = 1;

	private static final String MATH_MAX_METHOD = "<java.lang.Math: int max(int,int)>";
	private static final String MATH_MIN_METHOD = "<java.lang.Math: int min(int,int)>";
	
	private static final HashSet<String> MATH_LIBRARY_DB = new HashSet<String>();// = {MATH_MAX_METHOD, MATH_MIN_METHOD}; 

	public Z3JavaMathHandler() {
		MATH_LIBRARY_DB.add(MATH_MAX_METHOD);
		MATH_LIBRARY_DB.add(MATH_MIN_METHOD);	
	}

	protected boolean isJavaMathLibrary(Value value) {
		if(MATH_LIBRARY_DB.contains(this.getSootMethod(value).toString()))
			return true;
		return false;	
	}
	
	private SootMethod getSootMethod(Value value) {
		return ((InvokeExpr)value).getMethod();
	}

	protected Expr createMathEquality(Value value, Z3ScriptHandler z3Handler, Edge edge) {
		if(this.getSootMethod(value).toString().equals(Z3JavaMathHandler.MATH_MAX_METHOD))
			return maxEquality(value, z3Handler, edge);	
		if(this.getSootMethod(value).toString().equals(Z3JavaMathHandler.MATH_MIN_METHOD))
			return minEquality(value, z3Handler, edge);
		return null;
	}	

	private Expr maxEquality(Value value, Z3ScriptHandler z3Handler, Edge edge) {
		InterpolationContext ictx = z3Handler.getIctx();

		InvokeExpr iExpr = (InvokeExpr) value;
		Value arg0 = iExpr.getArg(this.arg0Index);
		Value arg1 = iExpr.getArg(this.arg1Index);

		Expr arg0Expr = z3Handler.convertValue(arg0, false, edge, edge.getSource().getDistance());
		Expr arg1Expr = z3Handler.convertValue(arg1, false, edge, edge.getSource().getDistance());

		return ictx.mkITE(ictx.mkGe((ArithExpr)arg0Expr, (ArithExpr)arg1Expr), arg0Expr, arg1Expr);
	}

	private Expr minEquality(Value value, Z3ScriptHandler z3Handler, Edge edge) {
		InterpolationContext ictx = z3Handler.getIctx();

		InvokeExpr iExpr = (InvokeExpr) value;
		Value arg0 = iExpr.getArg(this.arg0Index);
		Value arg1 = iExpr.getArg(this.arg1Index);

		Expr arg0Expr = z3Handler.convertValue(arg0, false, edge, edge.getSource().getDistance());
		Expr arg1Expr = z3Handler.convertValue(arg1, false, edge, edge.getSource().getDistance());

		return ictx.mkITE(ictx.mkLe((ArithExpr)arg0Expr, (ArithExpr)arg1Expr), arg0Expr, arg1Expr);
	}
}
