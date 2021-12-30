package org.lflang.generator;

import java.nio.file.Path;

import org.lflang.util.LFCommand;

/**
 * A means of validating generated code.
 */
public interface ValidationStrategy {

    /**
     * Returns the command that produces validation
     * output in association with `generatedFile`.
     */
    LFCommand getCommand(Path generatedFile);

    /**
     * Returns a strategy for parsing the stderr of the validation command.
     * @return A strategy for parsing the stderr of the validation command.
     */
    CommandErrorReportingStrategy getErrorReportingStrategy();

    /**
     * Returns a strategy for parsing the stdout of the validation command.
     * @return A strategy for parsing the stdout of the validation command.
     */
    CommandErrorReportingStrategy getOutputReportingStrategy();

    /**
     * Returns whether this strategy validates all generated files, as
     * opposed to just the given one.
     * @return whether this strategy validates all generated files
     */
    boolean isFullBatch();

    /**
     * Returns the priority of this. Strategies with higher
     * priorities are more likely to be used.
     * @return The priority of this.
     */
    int getPriority();
}
