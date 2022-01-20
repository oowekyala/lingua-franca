package org.lflang.generator;

import org.eclipse.xtext.util.CancelIndicator;

import org.lflang.ErrorReporter;
import org.lflang.util.LFCommand;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.stream.Collectors;

import com.google.common.collect.ImmutableMap;

/**
 * Validate generated code.
 *
 * @author Peter Donovan <peterdonovan@berkeley.edu>
 */
public abstract class Validator {

    protected static class Pair<S, T> {
        public final S first;
        public final T second;
        public Pair(S first, T second) {
            this.first = first;
            this.second = second;
        }
    }

    protected final ErrorReporter errorReporter;
    protected final ImmutableMap<Path, CodeMap> codeMaps;

    /**
     * Initialize a {@code Validator} that reports errors to {@code errorReporter} and adjusts
     * document positions using {@code codeMaps}.
     */
    protected Validator(ErrorReporter errorReporter, Map<Path, CodeMap> codeMaps) {
        this.errorReporter = errorReporter;
        this.codeMaps = ImmutableMap.copyOf(codeMaps);
    }

    /**
     * Validate this Validator's group of generated files.
     * @param cancelIndicator The cancel indicator for the
     * current operation.
     */
    public final void doValidate(CancelIndicator cancelIndicator) throws ExecutionException, InterruptedException {
        final List<Callable<Pair<ValidationStrategy, LFCommand>>> tasks = getValidationStrategies().stream().map(
            it -> (Callable<Pair<ValidationStrategy, LFCommand>>) () -> {
                it.second.run(cancelIndicator);
                return it;
            }
        ).collect(Collectors.toList());
        for (Future<Pair<ValidationStrategy, LFCommand>> f : getFutures(tasks)) {
            f.get().first.getErrorReportingStrategy().report(f.get().second.getErrors().toString(), errorReporter, codeMaps);
            f.get().first.getOutputReportingStrategy().report(f.get().second.getOutput().toString(), errorReporter, codeMaps);
        }
    }

    /**
     * Invoke all the given tasks.
     * @param tasks Any set of tasks.
     * @param <T> The return type of the tasks.
     * @return Futures corresponding to each task, or an empty list upon failure.
     * @throws InterruptedException If interrupted while waiting.
     */
    private static <T> List<Future<T>> getFutures(List<Callable<T>> tasks) throws InterruptedException {
        List<Future<T>> futures = List.of();
        switch (tasks.size()) {
        case 0:
            break;
        case 1:
            try {
                futures = List.of(CompletableFuture.completedFuture(tasks.get(0).call()));
            } catch (Exception e) {
                System.err.println(e.getMessage());  // This should never happen
            }
            break;
        default:
            futures = Executors.newFixedThreadPool(
                Math.min(Runtime.getRuntime().availableProcessors(), tasks.size())
            ).invokeAll(tasks);
        }
        return futures;
    }

    /**
     * Run the given command, report any messages produced using the reporting strategies
     * given by {@code getBuildReportingStrategies}, and return its return code.
     */
    public final int run(LFCommand command, CancelIndicator cancelIndicator) {
        final int returnCode = command.run(cancelIndicator);
        getBuildReportingStrategies().first.report(command.getErrors().toString(), errorReporter, codeMaps);
        getBuildReportingStrategies().second.report(command.getOutput().toString(), errorReporter, codeMaps);
        return returnCode;
    }

    /**
     * Return the validation strategies and validation
     * commands corresponding to each generated file.
     * @return the validation strategies and validation
     * commands corresponding to each generated file
     */
    private List<Pair<ValidationStrategy, LFCommand>> getValidationStrategies() {
        final List<Pair<ValidationStrategy, LFCommand>> commands = new ArrayList<>();
        for (Path generatedFile : codeMaps.keySet()) {
            final Pair<ValidationStrategy, LFCommand> p = getValidationStrategy(generatedFile);
            if (p.first == null || p.second == null) continue;
            commands.add(p);
            if (p.first.isFullBatch()) break;
        }
        return commands;
    }

    /**
     * Return the validation strategy and command
     * corresponding to the given file if such a strategy
     * and command are available.
     * @return the validation strategy and command
     * corresponding to the given file if such a strategy
     * and command are available
     */
    private Pair<ValidationStrategy, LFCommand> getValidationStrategy(Path generatedFile) {
        List<ValidationStrategy> sorted = getPossibleStrategies().stream()
            .sorted(Comparator.comparingInt(vs -> -vs.getPriority())).collect(Collectors.toList());
        for (ValidationStrategy strategy : sorted) {
            LFCommand validateCommand = strategy.getCommand(generatedFile);
            if (validateCommand != null) {
                return new Pair<>(strategy, validateCommand);
            }
        }
        return new Pair<>(null, null);
    }

    /**
     * List all validation strategies that exist for the implementor
     * without filtering by platform or availability.
     */
    protected abstract Collection<ValidationStrategy> getPossibleStrategies();

    /**
     * Return the appropriate output and error reporting
     * strategies for the main build process.
     */
    protected abstract Pair<DiagnosticReporting.Strategy, DiagnosticReporting.Strategy> getBuildReportingStrategies();
}
