namespace Calc.Tests;

public class CalculatorTests
{
    [Theory]
    [InlineData(1, 2, 3)]
    [InlineData(-1, 1, 0)]
    public void AddReturnsTheSum(int a, int b, int want) =>
        Assert.Equal(want, Calculator.Add(a, b));
}
