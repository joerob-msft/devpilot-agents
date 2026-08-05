# Synthetic engineering conventions

Generic fixture standing in for a large engineering-guidance document. It exists
so the section transport can be tested against the SHAPE of a real rule
document - many sibling rules, nested subsections, and a size far past any single
pack's budget - without copying anyone's guidance into this repository. Every
rule below is invented for this fixture.

## Coding patterns

### Immutable

#### Summary

An immutable object is one that once created, can't change. Prefer immutability
when possible.

#### Examples and counter-examples

**DO**

```csharp
    var filtered = candidates.Where(candidate => candidate != null).ToArray();
```

**DO NOT**

```csharp
    candidates = candidates.Where(candidate => candidate != null).ToArray();
```

### Thread-safe lazy initialization

#### Summary

Initialize shared state through a thread-safe primitive rather than a
double-checked lock written by hand.

## Coding style

### Name parameters for multi-line method call

#### Summary

Name each parameter if you linefeed between each parameter.

**DO**

```csharp
Assert.AreEqual(
    expected: expectedValue,
    actual: actualValue,
    message: "the values must match")
```

**DO NOT**

```csharp
Assert.AreEqual(
    expected: expectedValue,
    actual: actualValue,
    "the values must match")
```

### Casing of acronyms in comments

#### Summary

In code comments like all potentially user-visible strings, acronyms must be all
capital letters unless widely accepted casing in the relevant field is different.

**DO**

```csharp
    /// <summary>
    /// Parses XML Schema.
    /// </summary>
```

**DO NOT**

```csharp
    /// <summary>
    /// Parses xml Schema.
    /// </summary>
```

## Automated tests

### Claim ownership

Make it easier to identify test class or test case owner for troubleshooting by
adding the owner attribute on your test classes and methods.

**DO**

```csharp
        [TestMethod]
        [Owner("someone")]
        public void SomethingHappens()
```

### Adopt Arrange/Act/Assert pattern

Use the Arrange/Act/Assert pattern to write clean, readable tests.
