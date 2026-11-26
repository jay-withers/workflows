namespace Calc;

/// <summary>
/// The smallest library that exercises dotnet.yml's gates: _self_ci.yml runs
/// the reusable workflow against it with the lock-file check, warnings as
/// errors, dotnet format, coverage and diff-coverage on.
/// </summary>
public static class Calculator
{
    /// <summary>Returns the sum of <paramref name="a"/> and <paramref name="b"/>.</summary>
    public static int Add(int a, int b) => a + b;
}
