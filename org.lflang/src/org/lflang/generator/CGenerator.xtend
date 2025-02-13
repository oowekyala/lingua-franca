/* Generator for C target. */

/*************
Copyright (c) 2019-2021, The University of California at Berkeley.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
***************/

package org.lflang.generator

import java.io.File
import java.io.FileOutputStream
import java.math.BigInteger
import java.util.ArrayList
import java.util.Collection
import java.util.LinkedHashMap
import java.util.LinkedHashSet
import java.util.LinkedList
import java.util.Set
import java.util.regex.Pattern
import org.eclipse.emf.common.CommonPlugin
import org.eclipse.emf.ecore.EObject
import org.eclipse.emf.ecore.resource.Resource
import org.eclipse.xtext.generator.IFileSystemAccess2
import org.eclipse.xtext.generator.IGeneratorContext
import org.eclipse.xtext.nodemodel.util.NodeModelUtils
import org.lflang.ASTUtils
import org.lflang.FileConfig
import org.lflang.InferredType
import org.lflang.Target
import org.lflang.TargetProperty.ClockSyncMode
import org.lflang.TargetProperty.CoordinationType
import org.lflang.TargetProperty.LogLevel
import org.lflang.TimeValue
import org.lflang.federated.CGeneratorExtension
import org.lflang.lf.Action
import org.lflang.lf.ActionOrigin
import org.lflang.lf.Code
import org.lflang.lf.Delay
import org.lflang.lf.Input
import org.lflang.lf.Instantiation
import org.lflang.lf.Output
import org.lflang.lf.Port
import org.lflang.lf.Reaction
import org.lflang.lf.Reactor
import org.lflang.lf.ReactorDecl
import org.lflang.lf.StateVar
import org.lflang.lf.Timer
import org.lflang.lf.TriggerRef
import org.lflang.lf.TypedVariable
import org.lflang.lf.VarRef
import org.lflang.lf.Variable

import static extension org.lflang.ASTUtils.*

/** 
 * Generator for C target. This class generates C code definining each reactor
 * class given in the input .lf file and imported .lf files. The generated code
 * has the following components:
 * 
 * * A typedef for inputs, outputs, and actions of each reactor class. These
 *   define the types of the variables that reactions use to access inputs and
 *   action values and to set output values.
 * 
 * * A typedef for a "self" struct for each reactor class. One instance of this
 *   struct will be created for each reactor instance. See below for details.
 * 
 * * A function definition for each reaction in each reactor class. These
 *   functions take an instance of the self struct as an argument.
 * 
 * * A constructor function for each reactor class. This is used to create
 *   a new instance of the reactor.
 * 
 * * A destructor function for each reactor class. This frees all dynamically
 *   allocated memory associated with an instance of the class.
 * 
 * After these, the main generated function is `__initialize_trigger_objects()`.
 * This function creates the instances of reactors (using their constructors)
 * and makes connections between them.
 * 
 * A few other smaller functions are also generated.
 * 
 * ## Self Struct
 * 
 * The "self" struct has fields for each of the following:
 * 
 * * parameter: the field name and type match the parameter.
 * * state: the field name and type match the state.
 * * action: the field name prepends the action name with "__".
 *   A second field for the action is also created to house the trigger_t object.
 *   That second field prepends the action name with "___".
 * * output: the field name prepends the output name with "__".
 * * input:  the field name prepends the output name with "__".
 *   A second field for the input is also created to house the trigger_t object.
 *   That second field prepends the input name with "___".
 *
 * If, in addition, the reactor contains other reactors and reacts to their outputs,
 * then there will be a struct within the self struct for each such contained reactor.
 * The name of that self struct will be the name of the contained reactor prepended with "__".
 * That inside struct will contain pointers the outputs of the contained reactors
 * that are read together with pointers to booleans indicating whether those outputs are present.
 * 
 * If, in addition, the reactor has a reaction to shutdown, then there will be a pointer to
 * trigger_t object (see reactor.h) for the shutdown event and an action struct named
 * __shutdown on the self struct.
 * 
 * ## Reaction Functions
 * 
 * For each reaction in a reactor class, this generator will produce a C function
 * that expects a pointer to an instance of the "self" struct as an argument.
 * This function will contain verbatim the C code specified in the reaction, but
 * before that C code, the generator inserts a few lines of code that extract from the
 * self struct the variables that that code has declared it will use. For example, if
 * the reaction declares that it is triggered by or uses an input named "x" of type
 * int, the function will contain a line like this:
 * ```
 *     e_x_t* x = self->__x;
 * ```
 * where `r` is the full name of the reactor class and the struct type `r_x_t`
 * will be defined like this:
 * ```
 *     typedef struct {
 *         int value;
 *         bool is_present;
 *         int num_destinations;
 *     } r_x_t;
 * ```
 * The above assumes the type of `x` is `int`.
 * If the programmer fails to declare that it uses x, then the absence of the
 * above code will trigger a compile error when the verbatim code attempts to read `x`.
 *
 * ## Constructor
 * 
 * For each reactor class, this generator will create a constructor function named
 * `new_r`, where `r` is the reactor class name. This function will malloc and return
 * a pointer to an instance of the "self" struct.  This struct initially represents
 * an unconnected reactor. To establish connections between reactors, additional
 * information needs to be inserted (see below). The self struct is made visible
 * to the body of a reaction as a variable named "self".  The self struct contains the
 * following:
 * 
 * * Parameters: For each parameter `p` of the reactor, there will be a field `p`
 *   with the type and value of the parameter. So C code in the body of a reaction
 *   can access parameter values as `self->p`.
 * 
 * * State variables: For each state variable `s` of the reactor, there will be a field `s`
 *   with the type and value of the state variable. So C code in the body of a reaction
 *   can access state variables as as `self->s`.
 * 
 * The self struct also contains various fields that the user is not intended to
 * use. The names of these fields begin with at least two underscores. They are:
 * 
 * * Outputs: For each output named `out`, there will be a field `__out` that is
 *   a struct containing a value field whose type matches that of the output.
 *   The output value is stored here. That struct also has a field `is_present`
 *   that is a boolean indicating whether the output has been set.
 *   This field is reset to false at the start of every time
 *   step. There is also a field `num_destinations` whose value matches the
 *   number of downstream reactions that use this variable. This field must be
 *   set when connections are made or changed. It is used to initialize
 *   reference counts for dynamically allocated message payloads.
 * 
 * * Inputs: For each input named `in` of type T, there is a field named `__in`
 *   that is a pointer struct with a value field of type T. The struct pointed
 *   to also has an `is_present` field of type bool that indicates whether the
 *   input is present.
 * 
 * * Outputs of contained reactors: If a reactor reacts to outputs of a
 *   contained reactor `r`, then the self struct will contain a nested struct
 *   named `__r` that has fields pointing to those outputs. For example,
 *   if `r` has an output `out` of type T, then there will be field in `__r`
 *   named `out` that points to a struct containing a value field
 *   of type T and a field named `is_present` of type bool.
 * 
 * * Inputs of contained reactors: If a reactor sends to inputs of a
 *   contained reactor `r`, then the self struct will contain a nested struct
 *   named `__r` that has fields for storing the values provided to those
 *   inputs. For example, if R has an input `in` of type T, then there will
 *   be field in __R named `in` that is a struct with a value field
 *   of type T and a field named `is_present` of type bool.
 * 
 * * Actions: If the reactor has an action a (logical or physical), then there
 *   will be a field in the self struct named `__a` and another named `___a`.
 *   The type of the first is specific to the action and contains a `value`
 *   field with the type and value of the action (if it has a value). That
 *   struct also has a `has_value` field, an `is_present` field, and a
 *   `token` field (which is NULL if the action carries no value).
 *   The `___a` field is of type trigger_t.
 *   That struct contains various things, including an array of reactions
 *   sensitive to this trigger and a lf_token_t struct containing the value of
 *   the action, if it has a value.  See reactor.h in the C library for
 *   details.
 * 
 * * Reactions: Each reaction will have several fields in the self struct.
 *   Each of these has a name that begins with `___reaction_i`, where i is
 *   the number of the reaction, starting with 0. The fields are:
 *   * ___reaction_i: The struct that is put onto the reaction queue to
 *     execute the reaction (see reactor.h in the C library).
 * 
 *  * Timers: For each timer t, there is are two fields in the self struct:
 *    * ___t: The trigger_t struct for this timer (see reactor.h).
 *    * ___t_reactions: An array of reactions (pointers to the
 *      reaction_t structs on this self struct) sensitive to this timer.
 *
 * * Triggers: For each Timer, Action, Input, and Output of a contained
 *   reactor that triggers reactions, there will be a trigger_t struct
 *   on the self struct with name `___t`, where t is the name of the trigger.
 * 
 * ## Destructor
 * 
 * For each reactor class, this generator will create a constructor function named
 * `delete_r`, where `r` is the reactor class name. This function takes a self
 * struct for the class as an argument and frees all dynamically allocated memory
 * for the instance of the class. 
 * 
 * ## Connections Between Reactors
 * 
 * Establishing connections between reactors involves two steps.
 * First, each destination (e.g. an input port) must have pointers to
 * the source (the output port). As explained above, for an input named
 * `in`, the field `__in->value` is a pointer to the output data being read.
 * In addition, `__in->is_present` is a pointer to the corresponding
 * `out->is_present` field of the output reactor's self struct.
 *  
 * In addition, the `reaction_i` struct on the self struct has a `triggers`
 * field that records all the trigger_t structs for ports and reactions
 * that are triggered by the i-th reaction. The triggers field is
 * an array of arrays of pointers to trigger_t structs.
 * The length of the outer array is the number of output ports the
 * reaction effects plus the number of input ports of contained
 * reactors that it effects. Each inner array has a length equal to the
 * number final destinations of that output port or input port.
 * The reaction_i struct has an array triggered_sizes that indicates
 * the sizes of these inner arrays. The num_outputs field of the
 * reaction_i struct gives the length of the triggered_sizes and
 * (outer) triggers arrays.
 * 
 * ## Runtime Tables
 * 
 * This generator creates an populates the following tables used at run time.
 * These tables may have to be resized and adjusted when mutations occur.
 * 
 * * __is_present_fields: An array of pointers to booleans indicating whether an
 *   event is present. The __start_time_step() function in reactor_common.c uses
 *   this to mark every event absent at the start of a time step. The size of this
 *   table is contained in the variable __is_present_fields_size.
 * 
 * * __tokens_with_ref_count: An array of pointers to structs that point to lf_token_t
 *   objects, which carry non-primitive data types between reactors. This is used
 *   by the __start_time_step() function to decrement reference counts, if necessary,
 *   at the conclusion of a time step. Then the reference count reaches zero, the
 *   memory allocated for the lf_token_t object will be freed.  The size of this
 *   array is stored in the __tokens_with_ref_count_size variable.
 * 
 * * __shutdown_triggers: An array of pointers to trigger_t structs for shutdown
 *   reactions. The length of this table is in the __shutdown_triggers_size
 *   variable.
 * 
 * * __timer_triggers: An array of pointers to trigger_t structs for timers that
 *   need to be started when the program runs. The length of this table is in the
 *   __timer_triggers_size variable.
 * 
 * * __action_table: For a federated execution, each federate will have this table
 *   that maps port IDs to the corresponding trigger_t struct.
 * 
 * @author{Edward A. Lee <eal@berkeley.edu>}
 * @author{Marten Lohstroh <marten@berkeley.edu>}
 * @author{Mehrdad Niknami <mniknami@berkeley.edu>}
 * @author{Christian Menard <christian.menard@tu-dresden.de>}
 * @author{Matt Weber <matt.weber@berkeley.edu>}
 */
class CGenerator extends GeneratorBase {
    
    ////////////////////////////////////////////
    //// Private variables
        
    // Place to collect code to initialize the trigger objects for all reactor instances.
    protected var initializeTriggerObjects = new StringBuilder()

    // Place to collect code to go at the end of the __initialize_trigger_objects() function.
    var initializeTriggerObjectsEnd = new StringBuilder()

    /**
     * A representation of the dependencies between reactions as they are
     * inferred from the main reactor instance.
     */
    var ReactionInstanceGraph reactionGraph

    // The command to run the generated code if specified in the target directive.
    var runCommand = new ArrayList<String>()

    // Place to collect code to execute at the start of a time step.
    var startTimeStep = new StringBuilder()
    
    /** Count of the number of is_present fields of the self struct that
     *  need to be reinitialized in __start_time_step().
     */
    public var startTimeStepIsPresentCount = 0
    
    /** Count of the number of token pointers that need to have their
     *  reference count decremented in __start_time_step().
     */
    var startTimeStepTokens = 0

    // Place to collect code to initialize timers for all reactors.
    protected var startTimers = new StringBuilder()
    var timerCount = 0
    var startupReactionCount = 0
    var shutdownReactionCount = 0

    // For each reactor, we collect a set of input and parameter names.
    var triggerCount = 0


    new () {
        super()
        // set defaults
        targetConfig.compiler = "gcc"
        targetConfig.compilerFlags.add("-O2") // -Wall -Wconversion"
    }

    ////////////////////////////////////////////
    //// Public methods

    override printInfo() {
        super.printInfo()
        println('******** generated binaries: ' + fileConfig.binPath)
    }

    /**
     * Generate C code from the Lingua Franca model contained by the
     * specified resource. This is the main entry point for code
     * generation.
     * @param resource The resource containing the source code.
     * @param fsa The file system access (used to write the result).
     * @param context FIXME: Undocumented argument. No idea what this is.
     */
    override void doGenerate(Resource resource, IFileSystemAccess2 fsa,
            IGeneratorContext context) {
        
        // The following generates code needed by all the reactors.
        super.doGenerate(resource, fsa, context)        

        if (generatorErrorsOccurred) return;

        // Generate code for each reactor.
        val names = newLinkedHashSet
        for (r : reactors) {
            // Get the declarations for reactors that are instantiated somewhere.
            // A declaration is either a reactor definition or an import statement.
            val declarations = this.instantiationGraph.getDeclarations(r);
            for (d : declarations) {
                if (!names.add(d.name)) {
                    // Report duplicate declaration.
                    reportError("Multiple declarations for reactor class '" + d.name + "'.")
                }
                generateReactorFederated(d, null)
            }
            // If the reactor has no instantiations and there is no main reactor, then
            // generate code for it anyway (at a minimum, this means that the compiler is invoked
            // so that reaction bodies are checked).
            if (mainDef === null && declarations.isEmpty()) {
                generateReactorFederated(r, null)
            }
        }
        
        // Create the output directories if they don't yet exist.
        
        var dir = fileConfig.getSrcGenPath.toFile
        if (!dir.exists()) dir.mkdirs()
        dir = fileConfig.binPath.toFile
        if (!dir.exists()) dir.mkdirs()

        // Copy the required core library files into the target file system.
        // This will overwrite previous versions.
        // Note that net_util.h/c are not used by the infrastructure
        // unless the program is federated, but they are often useful for user code,
        // so we include them anyway.
        var coreFiles = newArrayList("net_util.c", "net_util.h", "reactor_common.c", "reactor.h", "pqueue.c", "pqueue.h", "tag.h", "tag.c", "trace.h", "trace.c", "util.h", "util.c", "platform.h")
        if (targetConfig.threads === 0) {
            coreFiles.add("reactor.c")
        } else {
            coreFiles.add("reactor_threaded.c")
        }
        // Check the operating system
        val OS = System.getProperty("os.name").toLowerCase();
        // FIXME: allow for cross-compiling
        // Based on the detected operating system, copy the required files
        // to enable platform-specific functionality. See lib/core/platform.h
        // for more detail.
        if ((OS.indexOf("mac") >= 0) || (OS.indexOf("darwin") >= 0)) {
            // Mac support
            coreFiles.add("platform/lf_POSIX_threads_support.c")
            coreFiles.add("platform/lf_C11_threads_support.c")
            coreFiles.add("platform/lf_POSIX_threads_support.h")
            coreFiles.add("platform/lf_C11_threads_support.h")
            coreFiles.add("platform/lf_macos_support.c")            
            coreFiles.add("platform/lf_macos_support.h")
            coreFiles.add("platform/lf_unix_clock_support.c")
            // If there is no main reactor, then compilation will produce a .o file requiring further linking.
            if (mainDef !== null) {
                targetConfig.compileAdditionalSources.add(fileConfig.getSrcGenPath + File.separator + "core/platform/lf_macos_support.c")
            }
        } else if (OS.indexOf("win") >= 0) {
            // Windows support
            coreFiles.add("platform/lf_C11_threads_support.c")
            coreFiles.add("platform/lf_C11_threads_support.h")
            coreFiles.add("platform/lf_windows_support.c")
            coreFiles.add("platform/lf_windows_support.h")
            // For 64-bit epoch time
            coreFiles.add("platform/lf_unix_clock_support.c")
            // If there is no main reactor, then compilation will produce a .o file requiring further linking.
            if (mainDef !== null) {
                targetConfig.compileAdditionalSources.add(fileConfig.getSrcGenPath + File.separator + "core/platform/lf_windows_support.c")
            }
        } else if (OS.indexOf("nux") >= 0) {
            // Linux support
            coreFiles.add("platform/lf_POSIX_threads_support.c")
            coreFiles.add("platform/lf_C11_threads_support.c")
            coreFiles.add("platform/lf_POSIX_threads_support.h")
            coreFiles.add("platform/lf_C11_threads_support.h")
            coreFiles.add("platform/lf_linux_support.c")
            coreFiles.add("platform/lf_linux_support.h")
            coreFiles.add("platform/lf_unix_clock_support.c")
            // If there is no main reactor, then compilation will produce a .o file requiring further linking.
            if (mainDef !== null) {
                targetConfig.compileAdditionalSources.add(fileConfig.getSrcGenPath + File.separator + "core/platform/lf_linux_support.c")
            }
        } else {
            reportError("Platform " + OS + " is not supported")
        }
        
        
        // If there are federates, copy the required files for that.
        // Also, create the RTI C file and the launcher script.
        if (isFederated) {
            coreFiles.addAll("rti.c", "rti.h", "federate.c", "federate.h", "clock-sync.h", "clock-sync.c")
            createFederateRTI()
            createLauncher(coreFiles)
        }
        
        copyFilesFromClassPath("/lib/core", fileConfig.getSrcGenPath + File.separator + "core", coreFiles)
        
        copyTargetHeaderFile()

        // Perform distinct code generation into distinct files for each federate.
        val baseFilename = topLevelName
        
        var commonCode = code;
        var commonStartTimers = startTimers;
        var compilationSucceeded = true
        for (federate : federates) {
            startTimeStepIsPresentCount = 0
            startTimeStepTokens = 0
            
            
            // If federated, append the federate name to the file name.
            // Only generate one output if there is no federation.
            if (isFederated) {
                topLevelName = baseFilename + '_' + federate.name // FIXME: don't (temporarily) reassign a class variable for this
                // Clear out previously generated code.
                code = new StringBuilder(commonCode)
                initializeTriggerObjects = new StringBuilder()
                initializeTriggerObjectsEnd = new StringBuilder()                
                        
                // Enable clock synchronization if the federate is not local and clock-sync is enabled
                initializeClockSynchronization(federate)
                

                startTimeStep = new StringBuilder()
                startTimers = new StringBuilder(commonStartTimers)
            }
        
            // Build the instantiation tree if a main reactor is present.
            if (this.mainDef !== null) {
                generateReactorFederated(this.mainDef.reactorClass, federate)
                if (this.main === null) {
                    // Recursively build instances. This is done once because
                    // it is the same for all federates.
                    this.main = new ReactorInstance(mainDef.reactorClass.toDefinition, this, 
                        this.unorderedReactions)
                    this.reactionGraph = new ReactionInstanceGraph(main)
                }   
            }
        
            // Derive target filename from the .lf filename.
            val cFilename = getTargetFileName(topLevelName);

            // Delete source previously produced by the LF compiler.
            var file = fileConfig.getSrcGenPath.resolve(cFilename).toFile
            if (file.exists) {
                file.delete
            }

            // Delete binary previously produced by the C compiler.
            file = fileConfig.binPath.resolve(topLevelName).toFile
            if (file.exists) {
                file.delete
            }

            // Generate main instance, if there is one.
            // Note that any main reactors in imported files are ignored.        
            if (this.main !== null) {
                generateReactorInstance(this.main, federate)
                // Generate function to set default command-line options.
                // A literal array needs to be given outside any function definition,
                // so start with that.
                if (runCommand.length > 0) {
                    pr('char* __default_argv[] = {"' + runCommand.join('", "') + '"};')
                }
                pr('void __set_default_command_line_options() {\n')
                indent()
                if (runCommand.length > 0) {
                    pr('default_argc = ' + runCommand.length + ';')
                    pr('default_argv = __default_argv;')
                }
                unindent()
                pr('}\n')
                
                // If there are timers, create a table of timers to be initialized.
                if (timerCount > 0) {
                    pr('''
                        // Array of pointers to timer triggers to be scheduled in __initialize_timers().
                        trigger_t* __timer_triggers[«timerCount»];
                    ''')
                } else {
                    pr('''
                        // Array of pointers to timer triggers to be scheduled in __initialize_timers().
                        trigger_t** __timer_triggers = NULL;
                    ''')
                }
                pr('''
                    int __timer_triggers_size = «timerCount»;
                ''')
                
                // If there are startup reactions, store them in an array.
                if (startupReactionCount > 0) {
                    pr('''
                        // Array of pointers to timer triggers to be scheduled in __trigger_startup_reactions().
                        reaction_t* __startup_reactions[«startupReactionCount»];
                    ''')
                } else {
                    pr('''
                        // Array of pointers to reactions to be scheduled in __trigger_startup_reactions().
                        reaction_t** __startup_reactions = NULL;
                    ''')
                }
                pr('''
                    int __startup_reactions_size = «startupReactionCount»;
                ''')
                
                // If there are shutdown reactions, create a table of triggers.
                if (shutdownReactionCount > 0) {
                    pr('''
                        // Array of pointers to shutdown triggers.
                        reaction_t* __shutdown_reactions[«shutdownReactionCount»];
                    ''')
                } else {
                    pr('''
                        // Empty array of pointers to shutdown triggers.
                        reaction_t** __shutdown_reactions = NULL;
                    ''')
                }
                pr('''
                    int __shutdown_reactions_size = «shutdownReactionCount»;
                ''')
                
                // Generate function to return a pointer to the action trigger_t
                // that handles incoming network messages destined to the specified
                // port. This will only be used if there are federates.
                if (federate.networkMessageActions.size > 0) {
                    pr('''trigger_t* __action_table[«federate.networkMessageActions.size»];''')
                }
                pr('trigger_t* __action_for_port(int port_id) {\n')
                indent()
                if (federate.networkMessageActions.size > 0) {
                    // Create a static array of trigger_t pointers.
                    // networkMessageActions is a list of Actions, but we
                    // need a list of trigger struct names for ActionInstances.
                    // There should be exactly one ActionInstance in the
                    // main reactor for each Action.
                    val triggers = new LinkedList<String>()
                    for (action : federate.networkMessageActions) {
                        // Find the corresponding ActionInstance.
                        val actionInstance = main.lookupActionInstance(action)
                        triggers.add(triggerStructName(actionInstance))
                    }
                    var actionTableCount = 0
                    for (trigger : triggers) {
                        pr(initializeTriggerObjects, '''
                            __action_table[«actionTableCount++»] = &«trigger»;
                        ''')
                    }
                    pr('''
                        if (port_id < «federate.networkMessageActions.size») {
                            return __action_table[port_id];
                        } else {
                            return NULL;
                        }
                    ''')
                } else {
                    pr('return NULL;')
                }
                unindent()
                pr('}\n')
                
                // Generate function to initialize the trigger objects for all reactors.
                pr('void __initialize_trigger_objects() {\n')
                indent()
                
                // Create the table used to decrement reference counts between time steps.
                if (startTimeStepTokens > 0) {
                    // Allocate the initial (before mutations) array of pointers to tokens.
                    pr('''
                        __tokens_with_ref_count_size = «startTimeStepTokens»;
                        __tokens_with_ref_count = (token_present_t*)malloc(«startTimeStepTokens» * sizeof(token_present_t));
                    ''')
                }
                // Create the table to initialize is_present fields to false between time steps.
                if (startTimeStepIsPresentCount > 0) {
                    // Allocate the initial (before mutations) array of pointers to _is_present fields.
                    pr('''
                        // Create the array that will contain pointers to is_present fields to reset on each step.
                        __is_present_fields_size = «startTimeStepIsPresentCount»;
                        __is_present_fields = (bool**)malloc(«startTimeStepIsPresentCount» * sizeof(bool*));
                    ''')
                }
                
                // Allocate the memory for triggers used in federated execution
                pr(CGeneratorExtension.allocateTriggersForFederate(federate, this));
                // Assign appropriate pointers to the triggers
                pr(initializeTriggerObjectsEnd,
                    CGeneratorExtension.initializeTriggerForControlReactions(this.main, federate, this));
                
                pr(initializeTriggerObjects.toString)
                pr('// Populate arrays of trigger pointers.')
                pr(initializeTriggerObjectsEnd.toString)
                doDeferredInitialize(federate)
                
                // Put the code here to set up the tables that drive resetting is_present and
                // decrementing reference counts between time steps. This code has to appear
                // in __initialize_trigger_objects() after the code that makes connections
                // between inputs and outputs.
                pr(startTimeStep.toString)
                
                setReactionPriorities(main, federate)
                
                // Initialize the LF clock.
                pr('''
                    lf_initialize_clock();
                ''')
                
                initializeFederate(federate)
                unindent()
                pr('}\n')

                // Generate function to trigger startup reactions for all reactors.
                pr("void __trigger_startup_reactions() {")
                indent()
                pr(startTimers.toString) // FIXME: these are actually startup actions, not timers.
                if (startupReactionCount > 0) {
                    pr('''
                       for (int i = 0; i < __startup_reactions_size; i++) {
                           if (__startup_reactions[i] != NULL) {
                               _lf_enqueue_reaction(__startup_reactions[i]);
                           }
                       }
                    ''')
                }
                unindent()
                pr("}")

                // Generate function to schedule timers for all reactors.
                pr("void __initialize_timers() {")
                indent()
                if (targetConfig.tracing !== null) {
                    var traceFileName = topLevelName;
                    if (targetConfig.tracing.traceFileName !== null) {
                        traceFileName = targetConfig.tracing.traceFileName;
                        // Since all federates would have the same name, we need to append the federate name.
                        if (!federate.isSingleton()) {
                            traceFileName += "_" + federate.name;
                        }
                    }
                    pr('''start_trace("«traceFileName».lft");''') // .lft is for Lingua Franca trace
                }
                if (timerCount > 0) {
                    pr('''
                       for (int i = 0; i < __timer_triggers_size; i++) {
                           if (__timer_triggers[i] != NULL) {
                               _lf_initialize_timer(__timer_triggers[i]);
                           }
                       }
                    ''')
                }
                unindent()
                pr("}")

                // Generate a function that will either do nothing
                // (if there is only one federate or the coordination 
                // is set to decentralized) or, if there are
                // downstream federates, will notify the RTI
                // that the specified logical time is complete.
                pr('''
                    void logical_tag_complete(tag_t tag_to_send) {
                        «IF isFederatedAndCentralized»
                            _lf_logical_tag_complete(tag_to_send);
                        «ENDIF»
                    }
                ''')
                                
                // Generate function to schedule shutdown reactions if any
                // reactors have reactions to shutdown.
                pr('''
                    bool __trigger_shutdown_reactions() {                          
                        for (int i = 0; i < __shutdown_reactions_size; i++) {
                            if (__shutdown_reactions[i] != NULL) {
                                _lf_enqueue_reaction(__shutdown_reactions[i]);
                            }
                        }
                        // Return true if there are shutdown reactions.
                        return (__shutdown_reactions_size > 0);
                    }
                ''')
                
                // Generate an empty termination function for non-federated
                // execution. For federated execution, an implementation is
                // provided in federate.c.  That implementation will resign
                // from the federation and close any open sockets.
                if (!isFederated) {
                    pr("void terminate_execution() {}");
                }
            }
            val targetFile = fileConfig.getSrcGenPath + File.separator + cFilename
            writeSourceCodeToFile(getCode().getBytes(), targetFile)
            
            // Create docker file.
            if (targetConfig.dockerOptions !== null) {
                writeDockerFile(topLevelName)
            }

            // If this code generator is directly compiling the code, compile it now so that we
            // clean it up after, removing the #line directives after errors have been reported.
            if (!targetConfig.noCompile && targetConfig.buildCommands.nullOrEmpty) {
                if (!runCCompiler(topLevelName, true)) {
                    compilationSucceeded = false
                }
                writeSourceCodeToFile(getCode.removeLineDirectives.getBytes(), targetFile)
            }
        }
        // Restore the base filename.
        topLevelName = baseFilename
        
        // If a build directive has been given, invoke it now.
        // Note that the code does not get cleaned in this case.
        if (!targetConfig.noCompile) {
            if (!targetConfig.buildCommands.nullOrEmpty) {
                runBuildCommand()
            } else if (isFederated) {
                // Compile the RTI files if there is more than one federate.
                compileRTI()
            }
        }
        
        // If compilation failed, remove any bin files that may have been created.
        if (!compilationSucceeded) {
            fileConfig.deleteBinFiles()
        }
        // In case we are in Eclipse, make sure the generated code is visible.
        refreshProject()
    }
    
    /**
     * Write a Dockerfile for the current federate as given by filename.
     * The file will go into src-gen/filename.Dockerfile.
     * If there is no main reactor, then no Dockerfile will be generated
     * (it wouldn't be very useful).
     * @param The root filename (without any extension).
     */
    def writeDockerFile(String filename) {
        if (this.mainDef === null) {
            return
        }
        
        var srcGenPath = fileConfig.getSrcGenPath
        val dockerFile = srcGenPath + File.separator + filename + '.Dockerfile'
        val contents = new StringBuilder()
        
        // If a dockerfile exists, remove it.
        var file = new File(dockerFile)
        if (file.exists) {
            file.delete
        }
        // The Docker configuration uses gcc, so config.compiler is ignored here.
        var compileCommand = '''gcc «targetConfig.compilerFlags.join(" ")» src-gen/«filename».c -o bin/«filename»'''
        if (!targetConfig.buildCommands.nullOrEmpty) {
            compileCommand = targetConfig.buildCommands.join(' ')
        }
        var additionalFiles = ''
        if (!targetConfig.fileNames.nullOrEmpty) {
            additionalFiles = '''COPY "«targetConfig.fileNames.join('" "')»" "src-gen/"'''
        }
        pr(contents, '''
            # Generated docker file for «topLevelName».lf in «srcGenPath».
            # For instructions, see: https://github.com/icyphy/lingua-franca/wiki/Containerized-Execution
            FROM «targetConfig.dockerOptions.from»
            WORKDIR /lingua-franca
            COPY src-gen/core src-gen/core
            COPY "src-gen/«filename».c" "src-gen/ctarget.h" "src-gen/"
            «additionalFiles»
            RUN set -ex && \
                apk add --no-cache gcc musl-dev && \
                mkdir bin && \
                «compileCommand» && \
                apk del gcc musl-dev && \
                rm -rf src-gen
            # Use ENTRYPOINT not CMD so that command-line arguments go through
            ENTRYPOINT ["./bin/«filename»"]
        ''')
        writeSourceCodeToFile(contents.toString.getBytes, dockerFile)
        println("Dockerfile written to " + dockerFile)
    }
    
    /**
     * Initialize clock synchronization (if enabled) and its related options for a given federate.
     * 
     * Clock synchronization can be enabled using the clock-sync target property.
     * @see https://github.com/icyphy/lingua-franca/wiki/Distributed-Execution#clock-synchronization
     * 
     * @param federate The federate to initialize clock synchronizatino for
     */
    protected def initializeClockSynchronization(FederateInstance federate) {
        // Check if clock synchronization should be enabled for this federate in the first place
        if (targetConfig.clockSync != ClockSyncMode.OFF
            && (!federationRTIProperties.get('host').toString.equals(federate.host) 
            || targetConfig.clockSyncOptions.localFederatesOn)
        ) {
            // Insert the #defines at the beginning
            code.insert(0, '''
                #define _LF_CLOCK_SYNC_INITIAL
                #define _LF_CLOCK_SYNC_PERIOD_NS «targetConfig.clockSyncOptions.period»
                #define _LF_CLOCK_SYNC_EXCHANGES_PER_INTERVAL «targetConfig.clockSyncOptions.trials»
                #define _LF_CLOCK_SYNC_ATTENUATION «targetConfig.clockSyncOptions.attenuation»
            ''')
            System.out.println("Initial clock synchronization is enabled for federate "
                + federate.id
            );
            if (targetConfig.clockSync == ClockSyncMode.ON) {
                var collectStatsEnable = ''
                if (targetConfig.clockSyncOptions.collectStats) {
                    collectStatsEnable = "#define _LF_CLOCK_SYNC_COLLECT_STATS"
                    System.out.println("Will collect clock sync statistics for federate " + federate.id)
                    // Add libm to the compiler flags
                    // FIXME: This is a linker flag not compile flag but we don't have a way to add linker flags
                    // FIXME: This is probably going to fail on MacOS (especially using clang)
                    // because libm functions are builtin
                    targetConfig.compilerFlags.add("-lm")
                }
                code.insert(0, '''
                    #define _LF_CLOCK_SYNC_ON
                    «collectStatsEnable»
                ''')
                System.out.println("Runtime clock synchronization is enabled for federate "
                    + federate.id
                );
            }
        }
    }
    
    /**
     * If the number of federates is greater than one, then generate the code
     * that initializes global variables that describe the federate.
     * @param federate The federate instance.
     */
    protected def void initializeFederate(FederateInstance federate) {
        if (isFederated) {
            pr('''
                // ***** Start initializing the federated execution. */
            ''')            
            pr('''
                // Initialize the socket mutex
                lf_mutex_init(&outbound_socket_mutex);
                lf_cond_init(&port_status_changed);
            ''')
            
            if (isFederatedAndDecentralized) {
                val reactorInstance = main.getChildReactorInstance(federate.instantiation)
                for (param : reactorInstance.parameters) {
                    if (param.name.equalsIgnoreCase("STP_offset") && param.type.isTime) {
                        val stp = param.init.get(0).getTimeValue
                        if (stp !== null) {                        
                            pr('''
                                set_stp_offset(«stp.timeInTargetLanguage»);
                            ''')
                        }
                    }
                }
            }
            
            // Set indicator variables that specify whether the federate has
            // upstream logical connections.
            if (federate.dependsOn.size > 0) {
                pr('_fed.has_upstream  = true;')
            }
            if (federate.sendsTo.size > 0) {
                pr('_fed.has_downstream = true;')
            }
            // Set global variable identifying the federate.
            pr('''_lf_my_fed_id = «federate.id»;''');
            
            // We keep separate record for incoming and outgoing p2p connections to allow incoming traffic to be processed in a separate
            // thread without requiring a mutex lock.
            val numberOfInboundConnections = federate.inboundP2PConnections.length;
            val numberOfOutboundConnections  = federate.outboundP2PConnections.length;
            
            pr('''
                _fed.number_of_inbound_p2p_connections = «numberOfInboundConnections»;
                _fed.number_of_outbound_p2p_connections = «numberOfOutboundConnections»;
            ''')
            if (numberOfInboundConnections > 0) {
                pr('''
                    // Initialize the array of socket for incoming connections to -1.
                    for (int i = 0; i < NUMBER_OF_FEDERATES; i++) {
                        _fed.sockets_for_inbound_p2p_connections[i] = -1;
                    }
                ''')                    
            }
            if (numberOfOutboundConnections > 0) {                        
                pr('''
                    // Initialize the array of socket for outgoing connections to -1.
                    for (int i = 0; i < NUMBER_OF_FEDERATES; i++) {
                        _fed.sockets_for_outbound_p2p_connections[i] = -1;
                    }
                ''')                    
            }

            // If a test clock offset has been specified, insert code to set it here.
            if (targetConfig.clockSyncOptions.testOffset !== null) {
                pr('''
                    set_physical_clock_offset((1 + «federate.id») * «targetConfig.clockSyncOptions.testOffset.toNanoSeconds»LL);
                ''')
            }
            
            pr('''
                // Connect to the RTI. This sets _fed.socket_TCP_RTI and _lf_rti_socket_UDP.
                connect_to_rti("«federationRTIProperties.get('host')»", «federationRTIProperties.get('port')»);
            ''');            
            
            // Disable clock synchronization for the federate if it resides on the same host as the RTI,
            // unless that is overridden with the clock-sync-options target property.
            if (targetConfig.clockSync !== ClockSyncMode.OFF
                && (!federationRTIProperties.get('host').toString.equals(federate.host) 
                    || targetConfig.clockSyncOptions.localFederatesOn)
            ) {
                pr('''
                    synchronize_initial_physical_clock_with_rti(_fed.socket_TCP_RTI);
                ''')
            }
        
            if (numberOfInboundConnections > 0) {
                pr('''
                    // Create a socket server to listen to other federates.
                    // If a port is specified by the user, that will be used
                    // as the only possibility for the server. If not, the port
                    // will start from STARTING_PORT. The function will
                    // keep incrementing the port until the number of tries reaches PORT_RANGE_LIMIT.
                    create_server(«federate.port»);
                    // Connect to remote federates for each physical connection.
                    // This is done in a separate thread because this thread will call
                    // connect_to_federate for each outbound physical connection at the same
                    // time that the new thread is listening for such connections for inbound
                    // physical connections. The thread will live until all connections
                    // have been established.
                    lf_thread_create(&_fed.inbound_p2p_handling_thread_id, handle_p2p_connections_from_federates, NULL);
                ''')
            }
                            
            for (remoteFederate : federate.outboundP2PConnections) {
                pr('''connect_to_federate(«remoteFederate.id»);''')
            }
        }
    }
    
    /**
     * Copy target-specific header file to the src-gen directory.
     */
    def copyTargetHeaderFile() {
        copyFileFromClassPath("/lib/C/ctarget.h", fileConfig.getSrcGenPath + File.separator + "ctarget.h")
    }

    ////////////////////////////////////////////
    //// Code generators.
    
    /** Create the runtime infrastructure (RTI) source file.
     */
    override createFederateRTI() {
        // Derive target filename from the .lf filename.
        var cFilename = getTargetFileName(fileConfig.RTIBinName)
        
        

        // Delete source previously produced by the LF compiler.
        var file = fileConfig.getSrcGenPath.resolve(cFilename).toFile
        if (file.exists) {
            file.delete
        }

        // Delete binary previously produced by the C compiler.
        file = fileConfig.binPath.resolve(topLevelName).toFile
        if (file.exists) {
            file.delete
        }
        
        val rtiCode = new StringBuilder()
        pr(rtiCode, this.defineLogLevel)
        
        if (targetConfig.clockSync == ClockSyncMode.INITIAL) {
            pr(rtiCode, '''
                #define _LF_CLOCK_SYNC_INITIAL
                #define _LF_CLOCK_SYNC_PERIOD_NS «targetConfig.clockSyncOptions.period.toNanoSeconds»
                #define _LF_CLOCK_SYNC_EXCHANGES_PER_INTERVAL «targetConfig.clockSyncOptions.trials»
            ''')
        } else if (targetConfig.clockSync == ClockSyncMode.ON) {
            pr(rtiCode, '''
                #define _LF_CLOCK_SYNC_INITIAL
                #define _LF_CLOCK_SYNC_ON
                #define _LF_CLOCK_SYNC_PERIOD_NS «targetConfig.clockSyncOptions.period.toNanoSeconds»
                #define _LF_CLOCK_SYNC_EXCHANGES_PER_INTERVAL «targetConfig.clockSyncOptions.trials»
            ''')
        }
        pr(rtiCode, '''
            #ifdef NUMBER_OF_FEDERATES
            #undefine NUMBER_OF_FEDERATES
            #endif
            #define NUMBER_OF_FEDERATES «federates.size»
            #include "core/rti.c"
            int main(int argc, char* argv[]) {
        ''')
        indent(rtiCode)
        
        // Initialize the array of information that the RTI has about the
        // federates.
        // FIXME: No support below for some federates to be FAST and some REALTIME.
        pr(rtiCode, '''
            if (!process_args(argc, argv)) {
                // Processing command-line arguments failed.
                return -1;
            }
            printf("Starting RTI for %d federates in federation ID %s\n", NUMBER_OF_FEDERATES, federation_id);
            for (int i = 0; i < NUMBER_OF_FEDERATES; i++) {
                initialize_federate(i);
                «IF targetConfig.fastMode»
                    federates[i].mode = FAST;
                «ENDIF»
            }
            #pragma GCC diagnostic push
            #pragma GCC diagnostic ignored "-Wunused-variable"
            interval_t candidate_tmp;
            #pragma GCC diagnostic pop
        ''')
        // Initialize the arrays indicating connectivity to upstream and downstream federates.
        for(federate : federates) {
            if (!federate.dependsOn.keySet.isEmpty) {
                // Federate receives non-physical messages from other federates.
                // Initialize the upstream and upstream_delay arrays.
                val numUpstream = federate.dependsOn.keySet.size
                // Allocate memory for the arrays storing the connectivity information.
                pr(rtiCode, '''
                    federates[«federate.id»].upstream = (int*)malloc(sizeof(federate_t*) * «numUpstream»);
                    federates[«federate.id»].upstream_delay = (interval_t*)malloc(sizeof(interval_t*) * «numUpstream»);
                    federates[«federate.id»].num_upstream = «numUpstream»;
                ''')
                // Next, populate these arrays.
                // Find the minimum delay in the process.
                // FIXME: Zero delay is not really the same as a microstep delay.
                var count = 0;
                for (upstreamFederate : federate.dependsOn.keySet) {
                    pr(rtiCode, '''
                        federates[«federate.id»].upstream[«count»] = «upstreamFederate.id»;
                    ''')
                    // The minimum delay calculation needs to be made in the C code because it
                    // may depend on parameter values.
                    // FIXME: These would have to be top-level parameters, which don't really
                    // have any support yet. Ideally, they could be overridden on the command line.
                    // When that is done, they will need to be in scope here.
                    val delays = federate.dependsOn.get(upstreamFederate)
                    if (delays !== null) {
                        // There is at least one delay, so find the minimum.
                        // If there is no delay at all, this is encoded as NEVER.
                        pr(rtiCode, '''
                            federates[«federate.id»].upstream_delay[«count»] = NEVER;
                            candidate_tmp = FOREVER;
                        ''')
                        for (delay : delays) {
                            if (delay === null) {
                                // Use NEVER to encode no delay at all.
                                pr(rtiCode, '''
                                    candidate_tmp = NEVER;
                                ''')
                            } else {
                                var delayTime = delay.getTargetTime
                                if (delay.parameter !== null) {
                                    // The delay is given as a parameter reference. Find its value.
                                    delayTime = ASTUtils.getInitialTimeValue(delay.parameter).timeInTargetLanguage
                                }
                                pr(rtiCode, '''
                                    if («delayTime» < candidate_tmp) {
                                        candidate_tmp = «delayTime»;
                                    }
                                ''')
                            }
                        }
                        pr(rtiCode, '''
                            if (candidate_tmp < FOREVER) {
                                federates[«federate.id»].upstream_delay[«count»] = candidate_tmp;
                            }
                        ''')
                    } else {
                        // Use NEVER to encode no delay at all.
                        pr(rtiCode, '''
                            federates[«federate.id»].upstream_delay[«count»] = NEVER;
                        ''')
                    }
                    count++;
                }
            }
            // Next, set up the downstream array.
            if (!federate.sendsTo.keySet.isEmpty) {
                // Federate sends non-physical messages to other federates.
                // Initialize the downstream array.
                val numDownstream = federate.sendsTo.keySet.size
                // Allocate memory for the array.
                pr(rtiCode, '''
                    federates[«federate.id»].downstream = (int*)malloc(sizeof(federate_t*) * «numDownstream»);
                    federates[«federate.id»].num_downstream = «numDownstream»;
                ''')
                // Next, populate the array.
                // Find the minimum delay in the process.
                // FIXME: Zero delay is not really the same as a microstep delay.
                var count = 0;
                for (downstreamFederate : federate.sendsTo.keySet) {
                    pr(rtiCode, '''
                        federates[«federate.id»].downstream[«count»] = «downstreamFederate.id»;
                    ''')
                    count++;
                }
            }
        }
        
        // Start the RTI server before launching the federates because if it
        // fails, e.g. because the port is not available, then we don't want to
        // launch the federates.
        // Also, generate code that blocks until the federates resign.
        pr(rtiCode, '''
            int socket_descriptor = start_rti_server(«federationRTIProperties.get('port')»);
            wait_for_federates(socket_descriptor);
        ''')
        
        // Handle RTI's exit
        pr(rtiCode, '''
            printf("RTI is exiting.\n");
            return 0;
        ''')

        unindent(rtiCode)
        pr(rtiCode, "}")

        var fOut = new FileOutputStream(fileConfig.getSrcGenPath.resolve(cFilename).toFile);
        fOut.write(rtiCode.toString().getBytes())
        fOut.close()
        
        // Write a Dockerfile for the RTI.
        if (targetConfig.dockerOptions !== null) {
            writeDockerFile(fileConfig.RTIBinName)
        }
    }
    
    /**
     * Create the launcher shell scripts. This will create one or two files
     * in the output path (bin directory). The first has name equal to
     * the filename of the source file without the ".lf" extension.
     * This will be a shell script that launches the
     * RTI and the federates.  If, in addition, either the RTI or any
     * federate is mapped to a particular machine (anything other than
     * the default "localhost" or "0.0.0.0"), then this will generate
     * a shell script in the bin directory with name filename_distribute.sh
     * that copies the relevant source files to the remote host and compiles
     * them so that they are ready to execute using the launcher.
     * 
     * A precondition for this to work is that the user invoking this
     * code generator can log into the remote host without supplying
     * a password. Specifically, you have to have installed your
     * public key (typically found in ~/.ssh/id_rsa.pub) in
     * ~/.ssh/authorized_keys on the remote host. In addition, the
     * remote host must be running an ssh service.
     * On an Arch Linux system using systemd, for example, this means
     * running:
     * 
     *     sudo systemctl <start|enable> ssh.service
     * 
     * Enable means to always start the service at startup, whereas
     * start means to just start it this once.
     * 
     * On MacOS, open System Preferences from the Apple menu and 
     * click on the "Sharing" preference panel. Select the checkbox
     * next to "Remote Login" to enable it.
     * 
     * In addition, every host must have OpenSSL installed, with at least
     * version 1.1.1a.  You can check the version with
     * 
     *     openssl version
     * 
     * @param coreFiles The files from the core directory that must be
     *  copied to the remote machines.
     */
    def createLauncher(ArrayList<String> coreFiles) {
        // NOTE: It might be good to use screen when invoking the RTI
        // or federates remotely so you can detach and the process keeps running.
        // However, I was unable to get it working properly.
        // What this means is that the shell that invokes the launcher
        // needs to remain live for the duration of the federation.
        // If that shell is killed, the federation will die.
        // Hence, it is reasonable to launch the federation on a
        // machine that participates in the federation, for example,
        // on the machine that runs the RTI.  The command I tried
        // to get screen to work looks like this:
        // ssh -t «target» cd «path»; screen -S «filename»_«federate.name» -L bin/«filename»_«federate.name» 2>&1
        
        //var outPath = binGenPath

        val shCode = new StringBuilder()
        val distCode = new StringBuilder()
        pr(shCode, '''
            #!/bin/bash
            # Launcher for federated «topLevelName».lf Lingua Franca program.
            # Uncomment to specify to behave as close as possible to the POSIX standard.
            # set -o posix
            
            # Enable job control
            set -m
            shopt -s huponexit
            
            # Set a trap to kill all background jobs on error or control-C
            # Use two distinct traps so we can see which signal causes this.
            cleanup() {
                printf "Killing federate %s.\n" ${pids[*]}
                # The || true clause means this is not an error if kill fails.
                kill ${pids[@]} || true
                printf "#### Killing RTI %s.\n" ${RTI}
                kill ${RTI} || true
                exit 1
            }
            cleanup_err() {
                echo "#### Received ERR signal on line $1. Invoking cleanup()."
                cleanup
            }
            cleanup_sigint() {
                echo "#### Received SIGINT signal on line $1. Invoking cleanup()."
                cleanup
            }
            
            trap 'cleanup_err $LINENO' ERR
            trap 'cleanup_sigint $LINENO' SIGINT

            # Create a random 48-byte text ID for this federation.
            # The likelihood of two federations having the same ID is 1/16,777,216 (1/2^24).
            FEDERATION_ID=`openssl rand -hex 24`
            echo "Federate «topLevelName» in Federation ID "$FEDERATION_ID
            # Launch the federates:
        ''')
        val distHeader = '''
            #!/bin/bash
            # Distributor for federated «topLevelName».lf Lingua Franca program.
            # Uncomment to specify to behave as close as possible to the POSIX standard.
            # set -o posix
        '''
        val host = federationRTIProperties.get('host')
        var target = host

        var path = federationRTIProperties.get('dir')
        if(path === null) path = 'LinguaFrancaRemote'

        var user = federationRTIProperties.get('user')
        if (user !== null) {
            target = user + '@' + host
        }
        // Launch the RTI in the foreground.
        if (host == 'localhost' || host == '0.0.0.0') {
            // FIXME: the paths below will not work on Windows
            pr(shCode, '''
                echo "#### Launching the runtime infrastructure (RTI)."
                # The RTI is started first to allow proper boot-up
                # before federates will try to connect.
                # The RTI will be brought back to foreground
                # to be responsive to user inputs after all federates
                # are launched.
                «fileConfig.binPath.resolve(topLevelName) + FileConfig.RTI_BIN_SUFFIX» -i $FEDERATION_ID &
                # Store the PID of the RTI
                RTI=$!
                # Wait for the RTI to boot up before
                # starting federates (this could be done by waiting for a specific output
                # from the RTI, but here we use sleep)
                sleep 1
            ''')
        } else {
            // Start the RTI on the remote machine.
            // FIXME: Should $FEDERATION_ID be used to ensure unique directories, executables, on the remote host?
            // Copy the source code onto the remote machine and compile it there.
            if (distCode.length === 0) pr(distCode, distHeader)
            
            val logFileName = '''log/«topLevelName»_RTI.log'''
            val compileCommand = '''«this.targetConfig.compiler» «targetConfig.compilerFlags.join(" ")» src-gen/«topLevelName»_RTI.c -o bin/«topLevelName»_RTI -pthread'''
            
            // The mkdir -p flag below creates intermediate directories if needed.
            pr(distCode, '''
                cd «path»
                echo "Making directory «path» and subdirectories src-gen and path on host «target»"
                ssh «target» '\
                    mkdir -p «path»/src-gen «path»/bin «path»/log «path»/src-gen/core; \
                    echo "--------------" >> «path»/«logFileName»; \
                    date >> «path»/«logFileName»; \
                '
                pushd src-gen/core > /dev/null
                echo "Copying LF core files for RTI to host «target»"
                scp rti.c rti.h tag.c tag.h util.h util.c net_util.h net_util.c reactor.h pqueue.h trace.c trace.h «target»:«path»/src-gen/core
                popd > /dev/null
                pushd src-gen > /dev/null
                echo "Copying source files for RTI to host «target»"
                scp «topLevelName»_RTI.c ctarget.h «target»:«path»/src-gen
                popd > /dev/null
                echo "Compiling on host «target» using: «targetConfig.compiler» «targetConfig.compilerFlags.join(" ")» «path»/src-gen/«topLevelName»_RTI.c -o «path»/bin/«fileConfig.RTIBinName» -pthread"
                ssh «target» ' \
                    cd «path»; \
                    echo "In «path» compiling RTI with: «compileCommand»" >> «logFileName» 2>&1; \
                    # Capture the output in the log file and stdout.
                    «compileCommand» 2>&1 | tee -a «logFileName»;'
            ''')

            // Launch the RTI on the remote machine using ssh and screen.
            // The -t argument to ssh creates a virtual terminal, which is needed by screen.
            // The -S gives the session a name.
            // The -L option turns on logging. Unfortunately, the -Logfile giving the log file name
            // is not standardized in screen. Logs go to screenlog.0 (or screenlog.n).
            // FIXME: Remote errors are not reported back via ssh from screen.
            // How to get them back to the local machine?
            // Perhaps use -c and generate a screen command file to control the logfile name,
            // but screen apparently doesn't write anything to the log file!
            //
            // The cryptic 2>&1 reroutes stderr to stdout so that both are returned.
            // The sleep at the end prevents screen from exiting before outgoing messages from
            // the federate have had time to go out to the RTI through the socket.
            val executeCommand = '''bin/«fileConfig.RTIBinName» -i '$FEDERATION_ID' '''
            pr(shCode, '''
                echo "#### Launching the runtime infrastructure (RTI) on remote host «host»."
                # FIXME: Killing this ssh does not kill the remote process.
                # A double -t -t option to ssh forces creation of a virtual terminal, which
                # fixes the problem, but then the ssh command does not execute. The remote
                # federate does not start!
                ssh «target» 'cd «path»; \
                    echo "-------------- Federation ID: "'$FEDERATION_ID' >> «logFileName»; \
                    date >> «logFileName»; \
                    echo "In «path», executing RTI: «executeCommand»" 2>&1 | tee -a «logFileName»; \
                    «executeCommand» 2>&1 | tee -a «logFileName»' &
                # Store the PID of the channel to RTI
                RTI=$!
                # Wait for the RTI to boot up before
                # starting federates (this could be done by waiting for a specific output
                # from the RTI, but here we use sleep)
                sleep 1
            ''')
        }
                
        // Index used for storing pids of federates
        var federateIndex = 0
        for (federate : federates) {
            if (federate.host !== null && federate.host != 'localhost' && federate.host != '0.0.0.0') {
                if(distCode.length === 0) pr(distCode, distHeader)
                val logFileName = '''log/«topLevelName»_«federate.name».log'''
                val compileCommand = '''«targetConfig.compiler» src-gen/«topLevelName»_«federate.name».c -o bin/«topLevelName»_«federate.name» -pthread «targetConfig.compilerFlags.join(" ")»'''
                // FIXME: Should $FEDERATION_ID be used to ensure unique directories, executables, on the remote host?
                pr(distCode, '''
                    echo "Making directory «path» and subdirectories src-gen, src-gen/core, and log on host «federate.host»"
                    # The >> syntax appends stdout to a file. The 2>&1 appends stderr to the same file.
                    ssh «federate.host» '\
                        mkdir -p «path»/src-gen «path»/bin «path»/log «path»/src-gen/core; \
                        echo "--------------" >> «path»/«logFileName»; \
                        date >> «path»/«logFileName»;
                    '
                    pushd src-gen/core > /dev/null
                    echo "Copying LF core files to host «federate.host»"
                    scp «coreFiles.join(" ")» «federate.host»:«path»/src-gen/core
                    popd > /dev/null
                    pushd src-gen > /dev/null
                    echo "Copying source files to host «federate.host»"
                    scp «topLevelName»_«federate.name».c «FOR file:targetConfig.filesNamesWithoutPath SEPARATOR " "»«file»«ENDFOR» ctarget.h «federate.host»:«path»/src-gen
                    popd > /dev/null
                    echo "Compiling on host «federate.host» using: «compileCommand»"
                    ssh «federate.host» '\
                        cd «path»; \
                        echo "In «path» compiling with: «compileCommand»" >> «logFileName» 2>&1; \
                        # Capture the output in the log file and stdout.
                        «compileCommand» 2>&1 | tee -a «logFileName»;'
                ''')
                val executeCommand = '''bin/«topLevelName»_«federate.name» -i '$FEDERATION_ID' '''
                pr(shCode, '''
                    echo "#### Launching the federate «federate.name» on host «federate.host»"
                    # FIXME: Killing this ssh does not kill the remote process.
                    # A double -t -t option to ssh forces creation of a virtual terminal, which
                    # fixes the problem, but then the ssh command does not execute. The remote
                    # federate does not start!
                    ssh «federate.host» '\
                        cd «path»; \
                        echo "-------------- Federation ID: "'$FEDERATION_ID' >> «logFileName»; \
                        date >> «logFileName»; \
                        echo "In «path», executing: «executeCommand»" 2>&1 | tee -a «logFileName»; \
                        «executeCommand» 2>&1 | tee -a «logFileName»' &
                    pids[«federateIndex++»]=$!
                ''')                
            } else {
                pr(shCode, '''
                    echo "#### Launching the federate «federate.name»."
                    «fileConfig.binPath.resolve(topLevelName)»_«federate.name» -i $FEDERATION_ID &
                    pids[«federateIndex++»]=$!
                ''')                
            }
        }
        if (host == 'localhost' || host == '0.0.0.0') {
            // Local PID managements
            pr(shCode, '''
                echo "#### Bringing the RTI back to foreground so it can receive Control-C."
                fg %1
            ''')
        }
        // Wait for launched processes to finish
        pr(shCode, '''
            echo "RTI has exited. Wait for federates to exit."
            # Wait for launched processes to finish.
            # The errors are handled separately via trap.
            for pid in "${pids[@]}"
            do
                wait $pid
            done
            echo "All done."
        ''')

        // Write the launcher file.
        // Delete file previously produced, if any.
        var file = fileConfig.binPath.resolve(topLevelName).toFile
        if (file.exists) {
            file.delete
        }
                
        var fOut = new FileOutputStream(file)
        fOut.write(shCode.toString().getBytes())
        fOut.close()
        if (!file.setExecutable(true, false)) {
            reportWarning(null, "Unable to make launcher script executable.")
        }
        
        // Write the distributor file.
        // Delete the file even if it does not get generated.
        file = fileConfig.binPath.resolve(topLevelName + '_distribute.sh').toFile
        if (file.exists) {
            file.delete
        }
        if (distCode.length > 0) {
            fOut = new FileOutputStream(file)
            fOut.write(distCode.toString().getBytes())
            fOut.close()
            if (!file.setExecutable(true, false)) {
                reportWarning(null, "Unable to make distributor script executable.")
            }
        }
    }

    /** 
     * Generate a reactor class definition for the specified federate.
     * A class definition has four parts:
     * 
     * * Preamble code, if any, specified in the Lingua Franca file.
     * * A "self" struct type definition (see the class documentation above).
     * * A function for each reaction.
     * * A constructor for creating an instance.
     * * A destructor
     *  for deleting an instance.
     * 
     * If the reactor is the main reactor, then
     * the generated code may be customized. Specifically,
     * if the main reactor has reactions, these reactions
     * will not be generated if they are triggered by or send
     * data to contained reactors that are not in the federate.
     * @param reactor The parsed reactor data structure.
     * @param federate A federate name, or null to unconditionally generate.
     */
    def generateReactorFederated(ReactorDecl reactor, FederateInstance federate) {
        // FIXME: Currently we're not reusing definitions for declarations that point to the same definition.
        
        val defn = reactor.toDefinition
        
        if (reactor instanceof Reactor) {
            pr("// =============== START reactor class " + reactor.name)
        } else {
            pr("// =============== START reactor class " + defn.name + " as " + reactor.name)
        }
        
        // Preamble code contains state declarations with static initializers.
        generateUserPreamblesForReactor(defn)
            
        // Some of the following methods create lines of code that need to
        // go into the constructor.  Collect those lines of code here:
        val constructorCode = new StringBuilder()
        val destructorCode = new StringBuilder()
        generateAuxiliaryStructs(reactor, federate)
        generateSelfStruct(reactor, federate, constructorCode, destructorCode)
        generateReactions(reactor, federate)
        generateConstructor(reactor, federate, constructorCode)
        generateDestructor(reactor, federate, destructorCode)

        pr("// =============== END reactor class " + reactor.name)
        pr("")
    }
    
    /**
     * Generates preambles defined by user for a given reactor
     * @param reactor The given reactor
     */
    def generateUserPreamblesForReactor(Reactor reactor) {
        for (p : reactor.preambles ?: emptyList) {
            pr("// *********** From the preamble, verbatim:")
            prSourceLineNumber(p.code)
            pr(p.code.toText)
            pr("\n// *********** End of preamble.")
        }
    }
    
    /**
     * Generate a constructor for the specified reactor in the specified federate.
     * @param reactor The parsed reactor data structure.
     * @param federate A federate name, or null to unconditionally generate.
     * @param constructorCode Lines of code previously generated that need to
     *  go into the constructor.
     */
    protected def generateConstructor(
        ReactorDecl reactor, FederateInstance federate, StringBuilder constructorCode
    ) {
        val structType = selfStructType(reactor)
        pr('''
            «structType»* new_«reactor.name»() {
                «structType»* self = («structType»*)calloc(1, sizeof(«structType»));
                «constructorCode.toString»
                return self;
            }
        ''')
    }

    /**
     * Generate a destructor for the specified reactor in the specified federate.
     * @param decl AST node that represents the declaration of the reactor.
     * @param federate A federate name, or null to unconditionally generate.
     * @param destructorCode Lines of code previously generated that need to
     *  go into the destructor.
     */
    protected def generateDestructor(
        ReactorDecl decl, FederateInstance federate, StringBuilder destructorCode
    ) {
        // Append to the destructor code freeing the trigger arrays for each reaction.
        var reactor = decl.toDefinition
        var reactionCount = 0
        for (reaction : reactor.reactions) {
            if (federate === null || federate.containsReaction(reactor, reaction)) {
                pr(destructorCode, '''
                    for(int i = 0; i < self->___reaction_«reactionCount».num_outputs; i++) {
                        free(self->___reaction_«reactionCount».triggers[i]);
                    }
                ''')
            }
            // Increment the reaction count even if not in the federate for consistency.
            reactionCount++;
        }
        
        val structType = selfStructType(decl)
        pr('''
            void delete_«decl.name»(«structType»* self) {
                «destructorCode.toString»
                free(self);
            }
        ''')
    }
    
    /**
     * Generate the struct type definitions for inputs, outputs, and
     * actions of the specified reactor in the specified federate.
     * @param reactor The parsed reactor data structure.
     * @param federate A federate name, or null to unconditionally generate.
     */
    protected def generateAuxiliaryStructs(
        ReactorDecl decl, FederateInstance federate
    ) {
        val reactor = decl.toDefinition
        // In the case where there are incoming
        // p2p logical connections in decentralized
        // federated execution, there will be an
        // intended_tag field added to accommodate
        // the case where a reaction triggered by a
        // port or action is late due to network 
        // latency, etc..
        var StringBuilder federatedExtension = new StringBuilder();    
        if (isFederatedAndDecentralized) {
            federatedExtension.append('''
                «targetTagType» intended_tag;
            ''');
        }
        if (isFederated) {
            federatedExtension.append('''                
                «targetTimeType» physical_time_of_arrival;
            ''');
        }
        // First, handle inputs.
        for (input : reactor.allInputs) {
            var token = ''
            if (input.inferredType.isTokenType) {
                token = '''
                    lf_token_t* token;
                    int length;
                '''
            }
            pr(input, code, '''
                typedef struct {
                    «input.valueDeclaration»
                    bool is_present;
                    int num_destinations;
                    «token»
                    «federatedExtension.toString»
                } «variableStructType(input, decl)»;
            ''')
            
        }
        // Next, handle outputs.
        for (output : reactor.allOutputs) {
            var token = ''
            if (output.inferredType.isTokenType) {
                 token = '''
                    lf_token_t* token;
                    int length;
                 '''
            }
            pr(output, code, '''
                typedef struct {
                    «output.valueDeclaration»
                    bool is_present;
                    int num_destinations;
                    «token»
                    «federatedExtension.toString»
                } «variableStructType(output, decl)»;
            ''')

        }
        // Finally, handle actions.
        // The very first item on this struct needs to be
        // a trigger_t* because the struct will be cast to (trigger_t*)
        // by the schedule() functions to get to the trigger.
        for (action : reactor.allActions) {
            pr(action, code, '''
                typedef struct {
                    trigger_t* trigger;
                    «action.valueDeclaration»
                    bool is_present;
                    bool has_value;
                    lf_token_t* token;
                    «federatedExtension.toString»
                } «variableStructType(action, decl)»;
            ''')
            
        }
    }

    /**
     * For the specified port, return a declaration for port struct to
     * contain the value of the port. A multiport output with width 4 and
     * type int[10], for example, will result in this:
     * ```
     *     int value[10];
     * ```
     * There will be an array of size 4 of structs, each containing this value 
     * array.
     * @param port The port.
     * @return A string providing the value field of the port struct.
     */
    protected def valueDeclaration(Port port) {
        if (port.type === null && target.requiresTypes === true) {
            // This should have been caught by the validator.
            reportError(port, "Port is required to have a type: " + port.name)
            return ''
        }
        // Do not convert to lf_token_t* using lfTypeToTokenType because there
        // will be a separate field pointing to the token.
        // val portType = lfTypeToTokenType(port.inferredType)
        val portType = port.inferredType.targetType
        // If the port type has the form type[number], then treat it specially
        // to get a valid C type.
        val matcher = arrayPatternFixed.matcher(portType)
        if (matcher.find()) {
            // for int[10], the first match is int, the second [10].
            // The following results in: int* __foo[10];
            // if the port is an input and not a multiport.
            // An output multiport will result in, for example
            // int __out[4][10];
            return '''«matcher.group(1)» value«matcher.group(2)»;''';
        } else {
            return '''«portType» value;'''
        }
    }

    /**
     * For the specified action, return a declaration for action struct to
     * contain the value of the action. An action of
     * type int[10], for example, will result in this:
     * ```
     *     int* value;
     * ```
     * This will return an empty string for an action with no type.
     * @param action The action.
     * @return A string providing the value field of the action struct.
     */
    protected def valueDeclaration(Action action) {
        if (action.type === null && target.requiresTypes === true) {
            return ''
        }
        // Do not convert to lf_token_t* using lfTypeToTokenType because there
        // will be a separate field pointing to the token.
        val actionType = action.inferredType.targetType
        // If the input type has the form type[number], then treat it specially
        // to get a valid C type.
        val matcher = arrayPatternFixed.matcher(actionType)
        if (matcher.find()) {
            // for int[10], the first match is int, the second [10].
            // The following results in: int* foo;
            return '''«matcher.group(1)»* value;''';
        } else {
            val matcher2 = arrayPatternVariable.matcher(actionType)
            if (matcher2.find()) {
                // for int[], the first match is int.
                // The following results in: int* foo;
                return '''«matcher2.group(1)»* value;''';
            }
            return '''«actionType» value;'''
        }
    }

    /**
     * Generate the self struct type definition for the specified reactor
     * in the specified federate.
     * @param reactor The parsed reactor data structure.
     * @param federate A federate name, or null to unconditionally generate.
     * @param constructorCode Place to put lines of code that need to
     *  go into the constructor.
     * @param destructorCode Place to put lines of code that need to
     *  go into the destructor.
     */
    protected def generateSelfStruct(
        ReactorDecl decl,
        FederateInstance federate,
        StringBuilder constructorCode,
        StringBuilder destructorCode
    ) {
        val reactor = decl.toDefinition
        val selfType = selfStructType(decl)
        
        // Construct the typedef for the "self" struct.
        // Create a type name for the self struct.
        
        var body = new StringBuilder()
        
        // Extensions can add functionality to the CGenerator
        generateSelfStructExtension(body, decl, federate, constructorCode, destructorCode)
        
        // Handle bank_index
        pr(body, '''«targetBankIndexType» «targetBankIndex»;''');    
        
        // Next handle parameters.
        generateParametersForReactor(body, reactor)
        
        // Next handle states.
        generateStateVariablesForReactor(body, reactor)
        
        // Next handle actions.
        for (action : reactor.allActions) {
            pr(action, body, '''
                «variableStructType(action, decl)» __«action.name»;
            ''')
            // Initialize the trigger pointer in the action.
            pr(action, constructorCode, '''
                self->__«action.name».trigger = &self->___«action.name»;
            ''')
        }
        
        // Next handle inputs.
        for (input : reactor.allInputs) {
            // If the port is a multiport, the input field is an array of
            // pointers that will be allocated separately for each instance
            // because the sizes may be different. Otherwise, it is a simple
            // pointer.
            if (input.isMultiport) {
                pr(input, body, '''
                    // Multiport input array will be malloc'd later.
                    «variableStructType(input, decl)»** __«input.name»;
                    int __«input.name»__width;
                    // Default input (in case it does not get connected)
                    «variableStructType(input, decl)» __default__«input.name»;
                ''')
                // Add to the destructor code to free the malloc'd memory.
                pr(input, destructorCode, '''
                    free(self->__«input.name»);
                ''')
            } else {
                pr(input, body, '''
                    «variableStructType(input, decl)»* __«input.name»;
                    // width of -2 indicates that it is not a multiport.
                    int __«input.name»__width;
                    // Default input (in case it does not get connected)
                    «variableStructType(input, decl)» __default__«input.name»;
                ''')

                pr(input, constructorCode, '''
                    // Set input by default to an always absent default input.
                    self->__«input.name» = &self->__default__«input.name»;
                ''')
            }
        }

        // Next handle outputs.
        for (output : reactor.allOutputs) {
            // If the port is a multiport, create an array to be allocated
            // at instantiation.
            if (output.isMultiport) {
                pr(output, body, '''
                    // Array of output ports.
                    «variableStructType(output, decl)»* __«output.name»;
                    int __«output.name»__width;
                ''')
                // Add to the destructor code to free the malloc'd memory.
                pr(output, destructorCode, '''
                    free(self->__«output.name»);
                ''')
            } else {
                pr(output, body, '''
                    «variableStructType(output, decl)» __«output.name»;
                    int __«output.name»__width;
                ''')
            }
        }
        
        // If there are contained reactors that either receive inputs
        // from reactions of this reactor or produce outputs that trigger
        // reactions of this reactor, then we need to create a struct
        // inside the self struct for each contained reactor. That
        // struct has a place to hold the data produced by this reactor's
        // reactions and a place to put pointers to data produced by
        // the contained reactors.
        // The contents of the struct will be collected first so that
        // we avoid duplicate entries and then the struct will be constructed.
        val contained = new InteractingContainedReactors(reactor, federate);
        // Next generate the relevant code.
        generateInteractingContainedReactors(contained, body, constructorCode, destructorCode);
                
        // Next, generate the fields needed for each reaction.
        generateReactionAndTriggerStructs(body, decl, constructorCode, destructorCode, federate)
        if (body.length > 0) {
            pr('''
                typedef struct {
                    «body.toString»
                } «selfType»;
            ''')
        } else {
            // There are no fields for the self struct.
            // C compilers complain about empty structs, so we generate a placeholder.
            pr('''
                typedef struct {
                    bool hasContents;
                } «selfType»;
            ''')
        }
    }
    
    /**
     * Generate structs and associated code for contained reactors that
     * send or receive data to or from the container's reactions.
     * 
     * If there are contained reactors that either receive inputs
     * from reactions of this reactor or produce outputs that trigger
     * reactions of this reactor, then we need to create a struct
     * inside the self struct of the container for each contained reactor.
     * That struct has a place to hold the data produced by the container reactor's
     * reactions and a place to put pointers to data produced by
     * the contained reactors.
     * 
     * To use this, first construct an instance of the inner class
     * PortsReferencedInContainedReactors. The constructor for that class
     * figures out which contained reactors are relevant and which ports
     * and reactions interact.
     * 
     * @param contained An instance of PortsReferencedInContainedReactors.
     * @param body The place to put the struct definition for the contained reactors.
     * @param constructorCode The place to put matching code that goes in the container's constructor.
     * @param destructorCode The place to put matching code that goes in the container's destructor.
     */
    private def generateInteractingContainedReactors(
        InteractingContainedReactors contained,
        StringBuilder body,
        StringBuilder constructorCode,
        StringBuilder destructorCode
    ) {
        for (containedReactor : contained.containedReactors) {
            // Generate one struct for each contained reactor that interacts.
            pr(body, "struct {")
            indent(body)
            for (port : contained.portsOfInstance(containedReactor)) {
                if (port instanceof Input) {
                    // If the variable is a multiport, then the place to store the data has
                    // to be malloc'd at initialization.
                    if (!port.isMultiport) {
                        pr(port, body, '''
                            «variableStructType(port, containedReactor.reactorClass)» «port.name»;
                        ''')
                    } else {
                        // Memory will be malloc'd in initialization.
                        pr(port, body, '''
                            «variableStructType(port, containedReactor.reactorClass)»** «port.name»;
                            int «port.name»__width;
                        ''')
                        // Add to the destructor code to free the malloc'd memory.
                        // FIXME: Refactor so there is an array of pointers to free on the self struct.
                        /* Following isn't right for multiports in banks.
                        pr(port, destructorCode, '''
                            free(self->__«containedReactor.name».«port.name»);
                        ''')
                        */
                    }
                } else {
                    // Must be an output entry.
                    // Outputs of contained reactors are pointers to the source of data on the
                    // self struct of the container.
                    if (!port.isMultiport) {
                        pr(port, body, '''
                            «variableStructType(port, containedReactor.reactorClass)»* «port.name»;
                        ''')
                    } else {
                        // Here, we will use an array of pointers.
                        // Memory will be malloc'd in initialization.
                        pr(port, body, '''
                            «variableStructType(port, containedReactor.reactorClass)»** «port.name»;
                            int «port.name»__width;
                        ''')
                        // Add to the destructor code to free the malloc'd memory.
                        pr(port, destructorCode, '''
                            free(self->__«containedReactor.name».«port.name»);
                        ''')
                    }
                    pr(port, body, '''
                        trigger_t «port.name»_trigger;
                    ''')
                    if (isFederatedAndDecentralized) {
                        pr(port, constructorCode, '''
                            self->__«containedReactor.name».«port.name»_trigger.intended_tag = (tag_t) { .time = NEVER, .microstep = 0u};
                        ''')
                    }
                    val triggered = contained.reactionsTriggered(containedReactor, port)
                    if (triggered.size > 0) {
                        pr(port, body, '''
                            reaction_t* «port.name»_reactions[«triggered.size»];
                        ''')
                        var triggeredCount = 0
                        for (index : triggered) {
                            pr(port, constructorCode, '''
                                self->__«containedReactor.name».«port.name»_reactions[«triggeredCount++»] = &self->___reaction_«index»;
                            ''')
                        }
                        pr(port, constructorCode, '''
                            self->__«containedReactor.name».«port.name»_trigger.reactions = self->__«containedReactor.name».«port.name»_reactions;
                        ''')
                    } else {
                        // Since the self struct is created using calloc, there is no need to set
                        // self->__«containedReactor.name».«port.name»_trigger.reactions = NULL
                    }
                    // Since the self struct is created using calloc, there is no need to set
                    // self->__«containedReactor.name».«port.name»_trigger.token = NULL;
                    // self->__«containedReactor.name».«port.name»_trigger.is_present = false;
                    // self->__«containedReactor.name».«port.name»_trigger.is_timer = false;
                    // self->__«containedReactor.name».«port.name»_trigger.is_physical = false;
                    // self->__«containedReactor.name».«port.name»_trigger.drop = false;
                    // self->__«containedReactor.name».«port.name»_trigger.element_size = 0;
                    // self->__«containedReactor.name».«port.name»_trigger.intended_tag = (0, 0);
                    pr(port, constructorCode, '''
                        self->__«containedReactor.name».«port.name»_trigger.last = NULL;
                        self->__«containedReactor.name».«port.name»_trigger.number_of_reactions = «triggered.size»;
                    ''')
                    
                    if (isFederated) {
                        // Set the physical_time_of_arrival
                        pr(port, constructorCode, '''
                            self->__«containedReactor.name».«port.name»_trigger.physical_time_of_arrival = NEVER;
                        ''')
                    }
                }
            }
            unindent(body)
            var array = "";
            var width = -2;
            // If the instantiation is a bank, find the maximum bank width
            // to define an array.
            if (containedReactor.widthSpec !== null) {
                width = maxContainedReactorBankWidth(containedReactor, null, 0);
                array = "[" + width + "]";
            }
            pr(body, '''
                } __«containedReactor.name»«array»;
                int __«containedReactor.name»_width;
            ''');
            // FIXME: The following needs to be done for each instance
            // so that the width can be parameter, not in the constructor.
            pr(constructorCode, '''
                // Set the _width variable for all cases. This will be -2
                // if the reactor is not a bank of reactors.
                self->__«containedReactor.name»_width = «width»;
            ''')
        }
    }
    
    /**
     * This function is provided to allow extensions of the CGenerator to append the structure of the self struct
     * @param body The body of the self struct
     * @param decl The reactor declaration for the self struct
     * @param instance The current federate instance
     * @param constructorCode Code that is executed when the reactor is instantiated
     * @param destructorCode Code that is executed when the reactor instance is freed
     */
    def void generateSelfStructExtension(StringBuilder selfStructBody, ReactorDecl decl, FederateInstance instance, StringBuilder constructorCode, StringBuilder destructorCode) {
        // Do nothing
    }
    
    
    /**
     * Generate code for parameters variables of a reactor in the form "parameter.type parameter.name;"
     * @param reactor The reactor
     * @param builder The StringBuilder that the generated code is appended to
     * @return 
     */
    def generateParametersForReactor(StringBuilder builder, Reactor reactor) {
        for (parameter : reactor.allParameters) {
            // Check for targetBankIndex
            // FIXME: for now throw a reserved error
            if (parameter.name.equals(targetBankIndex)) {
                reportError('''«targetBankIndex» is reserved.''')
            }

            prSourceLineNumber(builder, parameter)
            pr(builder, parameter.getInferredType.targetType + ' ' + parameter.name + ';');
        }
    }
    
    /**
     * Generate code for state variables of a reactor in the form "stateVar.type stateVar.name;"
     * @param reactor The reactor
     * @param builder The StringBuilder that the generated code is appended to
     * @return 
     */
    def generateStateVariablesForReactor(StringBuilder builder, Reactor reactor) {        
        for (stateVar : reactor.allStateVars) {            
            // Check for targetBankIndex
            // FIXME: for now throw a reserved error
            if(stateVar.name.equals(targetBankIndex))
            {
                reportError('''«targetBankIndex» is reserved.''')
            }
            
            prSourceLineNumber(builder, stateVar)
            pr(builder, stateVar.getInferredType.targetType + ' ' + stateVar.name + ';');
        }
    }
    
    /**
     * Generate the fields of the self struct and statements for the constructor
     * to create and initialize a reaction_t struct for each reaction in the
     * specified reactor and a trigger_t struct for each trigger (input, action,
     * timer, or output of a contained reactor).
     * @param body The place to put the code for the self struct.
     * @param reactor The reactor.
     * @param constructorCode The place to put the constructor code.
     * @param constructorCode The place to put the destructor code.
     * @param federate The federate instance, or null if there is no federation.
     */
    protected def void generateReactionAndTriggerStructs(
        StringBuilder body, 
        ReactorDecl decl, 
        StringBuilder constructorCode, 
        StringBuilder destructorCode, 
        FederateInstance federate
    ) {
        var reactionCount = 0;
        val reactor = decl.toDefinition
        // Iterate over reactions and create initialize the reaction_t struct
        // on the self struct. Also, collect a map from triggers to the reactions
        // that are triggered by that trigger. Also, collect a set of sources
        // that are read by reactions but do not trigger reactions.
        // Finally, collect a set of triggers and sources that are outputs
        // of contained reactors. 
        val triggerMap = new LinkedHashMap<Variable,LinkedList<Integer>>()
        val sourceSet = new LinkedHashSet<Variable>()
        val outputsOfContainedReactors = new LinkedHashMap<Variable,Instantiation>
        val startupReactions = new LinkedHashSet<Integer>
        val shutdownReactions = new LinkedHashSet<Integer>
        for (reaction : reactor.allReactions) {
            if (federate === null || federate.containsReaction(reactor, reaction)) {
                // Create the reaction_t struct.
                pr(reaction, body, '''reaction_t ___reaction_«reactionCount»;''')
                
                // Create the map of triggers to reactions.
                for (trigger : reaction.triggers) {
                    // trigger may not be a VarRef (it could be "startup" or "shutdown").
                    if (trigger instanceof VarRef) {
                        var reactionList = triggerMap.get(trigger.variable)
                        if (reactionList === null) {
                            reactionList = new LinkedList<Integer>()
                            triggerMap.put(trigger.variable, reactionList)
                        }
                        reactionList.add(reactionCount)
                        if (trigger.container !== null) {
                            outputsOfContainedReactors.put(trigger.variable, trigger.container)
                        }
                    }
                    if (trigger.isStartup) {
                        startupReactions.add(reactionCount)
                    }
                    if (trigger.isShutdown) {
                        shutdownReactions.add(reactionCount)
                    }
                }
                // Create the set of sources read but not triggering.
                for (source : reaction.sources) {
                    sourceSet.add(source.variable)
                    if (source.container !== null) {
                        outputsOfContainedReactors.put(source.variable, source.container)
                    }
                }

                pr(destructorCode, '''
                    if (self->___reaction_«reactionCount».output_produced != NULL) {
                        free(self->___reaction_«reactionCount».output_produced);
                    }
                    if (self->___reaction_«reactionCount».triggers != NULL) {
                        free(self->___reaction_«reactionCount».triggers);
                    }
                    if (self->___reaction_«reactionCount».triggered_sizes != NULL) {
                        free(self->___reaction_«reactionCount».triggered_sizes);
                    }
                ''')

                var deadlineFunctionPointer = "NULL"
                if (reaction.deadline !== null) {
                    // The following has to match the name chosen in generateReactions
                    val deadlineFunctionName = decl.name.toLowerCase + '_deadline_function' + reactionCount
                    deadlineFunctionPointer = "&" + deadlineFunctionName
                }
                
                // Assign the STP handler
                var STPFunctionPointer = "NULL"
                if (reaction.stp !== null) {
                    // The following has to match the name chosen in generateReactions
                    val STPFunctionName = decl.name.toLowerCase + '_STP_function' + reactionCount
                    STPFunctionPointer = "&" + STPFunctionName
                }

                // Set the defaults of the reaction_t struct in the constructor.
                // Since the self struct is allocated using calloc, there is no need to set:
                // self->___reaction_«reactionCount».index = 0;
                // self->___reaction_«reactionCount».chain_id = 0;
                // self->___reaction_«reactionCount».pos = 0;
                // self->___reaction_«reactionCount».running = false;
                // self->___reaction_«reactionCount».deadline = 0LL;
                // self->___reaction_«reactionCount».is_STP_violated = false;
                pr(reaction, constructorCode, '''
                    self->___reaction_«reactionCount».number = «reactionCount»;
                    self->___reaction_«reactionCount».function = «reactionFunctionName(decl, reactionCount)»;
                    self->___reaction_«reactionCount».self = self;
                    self->___reaction_«reactionCount».deadline_violation_handler = «deadlineFunctionPointer»;
                    self->___reaction_«reactionCount».STP_handler = «STPFunctionPointer»;
                    self->___reaction_«reactionCount».name = "?";
                ''')

            }
            // Increment the reactionCount even if the reaction is not in the federate
            // so that reaction indices are consistent across federates.
            reactionCount++
        }
        
        // Next, create and initialize the trigger_t objects.
        // Start with the timers.
        for (timer : reactor.allTimers) {
            createTriggerT(body, timer, triggerMap, constructorCode, destructorCode)
            // Since the self struct is allocated using calloc, there is no need to set:
            // self->___«timer.name».is_physical = false;
            // self->___«timer.name».drop = false;
            // self->___«timer.name».element_size = 0;
            pr(constructorCode, '''
                self->___«timer.name».is_timer = true;
            ''')
            if (isFederatedAndDecentralized) {
                pr(constructorCode, '''
                    self->___«timer.name».intended_tag = (tag_t) { .time = NEVER, .microstep = 0u};
                ''')
            }
        }
        
        // Handle startup triggers.
        if (startupReactions.size > 0) {
            pr(body, '''
                trigger_t ___startup;
                reaction_t* ___startup_reactions[«startupReactions.size»];
            ''')
            if (isFederatedAndDecentralized) {
                pr(constructorCode, '''
                    self->___startup.intended_tag = (tag_t) { .time = NEVER, .microstep = 0u};
                ''')
            }
            var i = 0
            for (reactionIndex : startupReactions) {
                pr(constructorCode, '''
                    self->___startup_reactions[«i++»] = &self->___reaction_«reactionIndex»;
                ''')
            }
            pr(constructorCode, '''
                self->___startup.last = NULL;
                self->___startup.reactions = &self->___startup_reactions[0];
                self->___startup.number_of_reactions = «startupReactions.size»;
                self->___startup.is_timer = false;
            ''')
        }
        // Handle shutdown triggers.
        if (shutdownReactions.size > 0) {
            pr(body, '''
                trigger_t ___shutdown;
                reaction_t* ___shutdown_reactions[«shutdownReactions.size»];
            ''')
            if (isFederatedAndDecentralized) {
                pr(constructorCode, '''
                    self->___shutdown.intended_tag = (tag_t) { .time = NEVER, .microstep = 0u};
                ''')
            }
            var i = 0
            for (reactionIndex : shutdownReactions) {
                pr(constructorCode, '''
                    self->___shutdown_reactions[«i++»] = &self->___reaction_«reactionIndex»;
                ''')
            }
            pr(constructorCode, '''
                self->___shutdown.last = NULL;
                self->___shutdown.reactions = &self->___shutdown_reactions[0];
                self->___shutdown.number_of_reactions = «shutdownReactions.size»;
                self->___shutdown.is_timer = false;
            ''')
        }

        // Next handle actions.
        for (action : reactor.allActions) {
            createTriggerT(body, action, triggerMap, constructorCode, destructorCode)
            var isPhysical = "true";
            if (action.origin == ActionOrigin.LOGICAL) {
                isPhysical = "false";
            }
            var elementSize = "0"
            // If the action type is 'void', we need to avoid generating the code
            // 'sizeof(void)', which some compilers reject.
            if (action.type !== null && action.targetType.rootType != 'void') {
                elementSize = '''sizeof(«action.targetType.rootType»)'''
            }

            // Since the self struct is allocated using calloc, there is no need to set:
            // self->___«action.name».is_timer = false;
            pr(constructorCode, '''
                self->___«action.name».is_physical = «isPhysical»;
                «IF !action.policy.isNullOrEmpty»
                self->___«action.name».policy = «action.policy»;
                «ENDIF»
                self->___«action.name».element_size = «elementSize»;
            ''')
        }

        // Next handle inputs.
        for (input : reactor.allInputs) {            
            createTriggerT(body, input, triggerMap, constructorCode, destructorCode)
        }
    }
    
    /**
     * Define the trigger_t object on the self struct, an array of
     * reaction_t pointers pointing to reactions triggered by this variable,
     * and initialize the pointers in the array in the constructor.
     * @param body The place to write the self struct entries.
     * @param variable The trigger variable (Timer, Action, or Input).
     * @param triggerMap A map from Variables to a list of the reaction indices
     *  triggered by the variable.
     * @param constructorCode The place to write the constructor code.
     * @param destructorCode The place to write the destructor code.
     */
    private def void createTriggerT(
        StringBuilder body, 
        Variable variable,
        LinkedHashMap<Variable, LinkedList<Integer>> triggerMap,
        StringBuilder constructorCode,
        StringBuilder destructorCode
    ) {
        // variable is a port, a timer, or an action.
        pr(variable, body, '''
            trigger_t ___«variable.name»;
        ''')
        pr(variable, constructorCode, '''
            self->___«variable.name».last = NULL;
        ''')
        if (isFederatedAndDecentralized) {
            pr(variable, constructorCode, '''
                self->___«variable.name».intended_tag = (tag_t) { .time = NEVER, .microstep = 0u};
            ''')
        }
        // Generate the reactions triggered table.
        val reactionsTriggered = triggerMap.get(variable)
        if (reactionsTriggered !== null) {
            pr(variable, body, '''reaction_t* ___«variable.name»_reactions[«reactionsTriggered.size»];''')
            var count = 0
            for (reactionTriggered : reactionsTriggered) {
                prSourceLineNumber(constructorCode, variable)
                pr(variable, constructorCode, '''
                    self->___«variable.name»_reactions[«count»] = &self->___reaction_«reactionTriggered»;
                ''')
                count++
            }
            // Set up the trigger_t struct's pointer to the reactions.
            pr(variable, constructorCode, '''
                self->___«variable.name».reactions = &self->___«variable.name»_reactions[0];
                self->___«variable.name».number_of_reactions = «count»;
            ''')
            
            if (isFederated) {
                // Set the physical_time_of_arrival
                pr(variable, constructorCode, '''
                    self->___«variable.name».physical_time_of_arrival = NEVER;
                ''')
            }
        }
        if (variable instanceof Input) {
            val rootType = variable.targetType.rootType
            // Since the self struct is allocated using calloc, there is no need to set:
            // self->___«input.name».is_timer = false;
            // self->___«input.name».offset = 0LL;
            // self->___«input.name».period = 0LL;
            // self->___«input.name».is_physical = false;
            // self->___«input.name».drop = false;
            // If the input type is 'void', we need to avoid generating the code
            // 'sizeof(void)', which some compilers reject.
            val size = (rootType == 'void') ? '0' : '''sizeof(«rootType»)'''
            pr(constructorCode, '''
                self->___«variable.name».element_size = «size»;
            ''')
        
            if (isFederated) {
                pr(body,
                    CGeneratorExtension.createPortStatusFieldForInput(variable, this)                    
                );
            }
        
        }
    }    
    
    /** Generate reaction functions definition for a reactor.
     *  These functions have a single argument that is a void* pointing to
     *  a struct that contains parameters, state variables, inputs (triggering or not),
     *  actions (triggering or produced), and outputs.
     *  @param reactor The reactor.
     *  @param federate The federate, or null if this is not
     *   federated or not the main reactor and reactions should be
     *   unconditionally generated.
     */
    def generateReactions(ReactorDecl decl, FederateInstance federate) {
        var reactionIndex = 0;
        val reactor = decl.toDefinition
        for (reaction : reactor.allReactions) {
            if (federate === null || federate.containsReaction(reactor, reaction)) {
                generateReaction(reaction, decl, reactionIndex)
            }
            // Increment reaction index even if the reaction is not in the federate
            // so that across federates, the reaction indices are consistent.
            reactionIndex++
        }
    }
    
    /** Generate a reaction function definition for a reactor.
     *  This function will have a single argument that is a void* pointing to
     *  a struct that contains parameters, state variables, inputs (triggering or not),
     *  actions (triggering or produced), and outputs.
     *  @param reaction The reaction.
     *  @param reactor The reactor.
     *  @param reactionIndex The position of the reaction within the reactor. 
     */
    def generateReaction(Reaction reaction, ReactorDecl decl, int reactionIndex) {
        val functionName = reactionFunctionName(decl, reactionIndex)
        
        
        pr('void ' + functionName + '(void* instance_args) {')
        indent()
        var body = reaction.code.toText
        
        generateInitializationForReaction(body, reaction, decl, reactionIndex)
        
        // Code verbatim from 'reaction'
        prSourceLineNumber(reaction.code)
        pr(body)
        unindent()
        pr("}")

        // Now generate code for the late function, if there is one
        // Note that this function can only be defined on reactions
        // in federates that have inputs from a logical connection.
        if (reaction.stp !== null) {
            val lateFunctionName = decl.name.toLowerCase + '_STP_function' + reactionIndex

            pr('void ' + lateFunctionName + '(void* instance_args) {')
            indent();
            generateInitializationForReaction(body, reaction, decl, reactionIndex)
            // Code verbatim from 'late'
            prSourceLineNumber(reaction.stp.code)
            pr(reaction.stp.code.toText)
            unindent()
            pr("}")
        }

        // Now generate code for the deadline violation function, if there is one.
        if (reaction.deadline !== null) {
            // The following name has to match the choice in generateReactionInstances
            val deadlineFunctionName = decl.name.toLowerCase + '_deadline_function' + reactionIndex

            pr('void ' + deadlineFunctionName + '(void* instance_args) {')
            indent();
            generateInitializationForReaction(body, reaction, decl, reactionIndex)
            // Code verbatim from 'deadline'
            prSourceLineNumber(reaction.deadline.code)
            pr(reaction.deadline.code.toText)
            unindent()
            pr("}")
        }
    }
    
    /**
     * Generate code that passes existing intended tag to all output ports
     * and actions. This intended tag is the minimum intended tag of the 
     * triggering inputs of the reaction.
     * 
     * @param body The body of the reaction. Used to check for the DISABLE_REACTION_INITIALIZATION_MARKER.
     * @param reaction The initialization code will be generated for this specific reaction
     * @param decl The reactor that has the reaction
     * @param reactionIndex The index of the reaction relative to other reactions in the reactor, starting from 0
     */
    def generateIntendedTagInheritence(String body, Reaction reaction, ReactorDecl decl, int reactionIndex) {
        // Construct the intended_tag inheritance code to go into
        // the body of the function.
        var StringBuilder intendedTagInheritenceCode = new StringBuilder()
        // Check if the coordination mode is decentralized and if the reaction has any effects to inherit the STP violation
        if (isFederatedAndDecentralized && !reaction.effects.nullOrEmpty) {
            pr(intendedTagInheritenceCode, '''
                #pragma GCC diagnostic push
                #pragma GCC diagnostic ignored "-Wunused-variable"
                if (self->___reaction_«reactionIndex».is_STP_violated == true) {
            ''')
            indent(intendedTagInheritenceCode);            
            pr(intendedTagInheritenceCode, '''            
                // The operations inside this if clause (if any exists) are expensive 
                // and must only be done if the reaction has unhandled STP violation.
                // Otherwise, all intended_tag values are (NEVER, 0) by default.
                
                // Inherited intended tag. This will take the minimum
                // intended_tag of all input triggers
                «targetTagType» inherited_min_intended_tag = («targetTagType») { .time = FOREVER, .microstep = UINT_MAX };
            ''')
            pr(intendedTagInheritenceCode, '''
                // Find the minimum intended tag
            ''')
            // Go through every trigger of the reaction and check the
            // value of intended_tag to choose the minimum.
            for (TriggerRef inputTrigger : reaction.triggers ?: emptyList) {
                if (inputTrigger instanceof VarRef) {
                    if (inputTrigger.variable instanceof Output) {
                        // Output from a contained reactor
                        pr(intendedTagInheritenceCode, '''
                            if (compare_tags(«inputTrigger.container.name».«inputTrigger.variable.name»->intended_tag,
                                             inherited_min_intended_tag) < 0) {
                                inherited_min_intended_tag = «inputTrigger.container.name».«inputTrigger.variable.name»->intended_tag;
                            }
                        ''')
                    } else if (inputTrigger.variable instanceof Port) {
                        pr(intendedTagInheritenceCode, '''
                            if (compare_tags(«inputTrigger.variable.name»->intended_tag, inherited_min_intended_tag) < 0) {
                                inherited_min_intended_tag = «inputTrigger.variable.name»->intended_tag;
                            }
                        ''')
                    } else if (inputTrigger.variable instanceof Action) {
                        pr(intendedTagInheritenceCode, '''
                            if (compare_tags(«inputTrigger.variable.name»->trigger->intended_tag, inherited_min_intended_tag) < 0) {
                                inherited_min_intended_tag = «inputTrigger.variable.name»->trigger->intended_tag;
                            }
                        ''')
                    }

                }
            }
            if (reaction.triggers === null || reaction.triggers.size === 0) {
                // No triggers are given, which means the reaction would react to any input.
                // We need to check the intended tag for every input.
                // NOTE: this does not include contained outputs. 
                for (input : (reaction.eContainer as Reactor).inputs) {
                    pr(intendedTagInheritenceCode, '''
                        if (compare_tags(«input.name»->intended_tag, inherited_min_intended_tag) > 0) {
                            inherited_min_intended_tag = «input.name»->intended_tag;
                        }
                    ''')
                }
            }
            
            // Once the minimum intended tag has been found,
            // it will be passed down to the port effects
            // of the reaction. Note that the intended tag
            // will not pass on to actions downstream.
            // Last reaction that sets the intended tag for the effect
            // will be seen.
            pr(intendedTagInheritenceCode, '''
                // All effects inherit the minimum intended tag of input triggers
                if (inherited_min_intended_tag.time != NEVER) {
            ''')
            for (effect : reaction.effects ?: emptyList) {
                if (effect.variable instanceof Input) {
                    if ((effect.variable as Input).isMultiport) {
                        pr(intendedTagInheritenceCode, '''
                            for(int i=0; i < «effect.container.name».«effect.variable.name»_width; i++) {
                                «effect.container.name».«effect.variable.name»[i]->intended_tag = inherited_min_intended_tag;
                            }
                        ''')
                    } else {
                        // Input to a contained reaction
                        pr(intendedTagInheritenceCode, '''
                                // Don't reset the intended tag of the output port if it has already been set.
                                «effect.container.name».«effect.variable.name»->intended_tag = inherited_min_intended_tag;
                        ''')
                    }                   
                }
            }
            pr(intendedTagInheritenceCode, '''
                }
            ''')
            unindent(intendedTagInheritenceCode);
            pr(intendedTagInheritenceCode,'''
            }
            #pragma GCC diagnostic pop
            ''')
            
            // Write the the intended tag inheritance initialization
            // to the main code.
            pr(intendedTagInheritenceCode.toString) 
        }
        return intendedTagInheritenceCode
    }
    
    /**
     * Generate necessary initialization code inside the body of the reaction that belongs to reactor decl.
     * @param body The body of the reaction. Used to check for the DISABLE_REACTION_INITIALIZATION_MARKER.
     * @param reaction The initialization code will be generated for this specific reaction
     * @param decl The reactor that has the reaction
     * @param reactionIndex The index of the reaction relative to other reactions in the reactor, starting from 0
     */
    def generateInitializationForReaction(String body, Reaction reaction, ReactorDecl decl, int reactionIndex) {
        val reactor = decl.toDefinition
        
        // Construct the reactionInitialization code to go into
        // the body of the function before the verbatim code.
        var StringBuilder reactionInitialization = new StringBuilder()

        // Define the "self" struct.
        var structType = selfStructType(decl)
        // A null structType means there are no inputs, state,
        // or anything else. No need to declare it.
        if (structType !== null) {
             pr('''
                 #pragma GCC diagnostic push
                 #pragma GCC diagnostic ignored "-Wunused-variable"
                 «structType»* self = («structType»*)instance_args;
             ''')
        }

        // Do not generate the initialization code if the body is marked
        // to not generate it.
        if (body.startsWith(CGenerator.DISABLE_REACTION_INITIALIZATION_MARKER)) {
             pr('''
                 #pragma GCC diagnostic pop
             ''')
            return;
        }

        // A reaction may send to or receive from multiple ports of
        // a contained reactor. The variables for these ports need to
        // all be declared as fields of the same struct. Hence, we first
        // collect the fields to be defined in the structs and then
        // generate the structs.
        var fieldsForStructsForContainedReactors = new LinkedHashMap<Instantiation, StringBuilder>

        // Actions may appear twice, first as a trigger, then with the outputs.
        // But we need to declare it only once. Collect in this data structure
        // the actions that are declared as triggered so that if they appear
        // again with the outputs, they are not defined a second time.
        // That second redefinition would trigger a compile error.  
        var actionsAsTriggers = new LinkedHashSet<Action>();

        // Next, add the triggers (input and actions; timers are not needed).
        // This defines a local variable in the reaction function whose
        // name matches that of the trigger. The value of the local variable
        // is a struct with a value and is_present field, the latter a boolean
        // that indicates whether the input/action is present.
        // If the trigger is an output, then it is an output of a
        // contained reactor. In this case, a struct with the name
        // of the contained reactor is created with one field that is
        // a pointer to a struct with a value and is_present field.
        // E.g., if the contained reactor is named 'c' and its output
        // port is named 'out', then c.out->value c.out->is_present are
        // defined so that they can be used in the verbatim code.
        for (TriggerRef trigger : reaction.triggers ?: emptyList) {
            if (trigger instanceof VarRef) {
                if (trigger.variable instanceof Port) {
                    generatePortVariablesInReaction(reactionInitialization,
                        fieldsForStructsForContainedReactors, trigger, decl)
                } else if (trigger.variable instanceof Action) {
                    generateActionVariablesInReaction(
                        reactionInitialization, trigger.variable as Action, decl
                    )
                    actionsAsTriggers.add(trigger.variable as Action);
                }
            }
        }
        if (reaction.triggers === null || reaction.triggers.size === 0) {
            // No triggers are given, which means react to any input.
            // Declare an argument for every input.
            // NOTE: this does not include contained outputs. 
            for (input : reactor.inputs) {
                generateInputVariablesInReaction(reactionInitialization, input, decl)
            }
        }
        // Define argument for non-triggering inputs.
        for (VarRef src : reaction.sources ?: emptyList) {
            if (src.variable instanceof Port) {
                generatePortVariablesInReaction(reactionInitialization, fieldsForStructsForContainedReactors, src, decl)
            } else if (src.variable instanceof Action) {
                // It's a bit odd to read but not be triggered by an action, but
                // OK, I guess we allow it.
                generateActionVariablesInReaction(
                    reactionInitialization,
                    src.variable as Action,
                    decl
                )
                actionsAsTriggers.add(src.variable as Action);
            }
        }

        // Define variables for each declared output or action.
        // In the case of outputs, the variable is a pointer to where the
        // output is stored. This gives the reaction code access to any previous
        // value that may have been written to that output in an earlier reaction.
        if (reaction.effects !== null) {
            for (effect : reaction.effects) {
                if (effect.variable instanceof Action) {
                    // It is an action, not an output.
                    // If it has already appeared as trigger, do not redefine it.
                    if (!actionsAsTriggers.contains(effect.variable)) {
                        pr(reactionInitialization, '''
                            «variableStructType(effect.variable, decl)»* «effect.variable.name» = &self->__«effect.variable.name»;
                        ''')
                    }
                } else {
                    if (effect.variable instanceof Output) {
                        generateOutputVariablesInReaction(reactionInitialization, effect.variable as Output, decl)
                    } else if (effect.variable instanceof Input) {
                        // It is the input of a contained reactor.
                        generateVariablesForSendingToContainedReactors(
                            reactionInitialization,
                            fieldsForStructsForContainedReactors,
                            effect.container,
                            effect.variable as Input
                        )
                    } else {
                        reportError(
                            reaction,
                            "In generateReaction(): " + effect.variable.name + " is neither an input nor an output."
                        )
                    }
                }
            }
        }
        // Before the reaction initialization,
        // generate the structs used for communication to and from contained reactors.
        for (containedReactor : fieldsForStructsForContainedReactors.keySet) {
            pr('struct ' + containedReactor.name + '{')
            indent();
            pr(fieldsForStructsForContainedReactors.get(containedReactor).toString)
            unindent();
            var array = "";
            if (containedReactor.widthSpec !== null) {
                array = '''[self->__«containedReactor.name»_width]''';
            }
            pr('''
                } «containedReactor.name»«array»;
            ''');
        }
        // Next generate all the collected setup code.
        pr(reactionInitialization.toString)
        pr('''
            #pragma GCC diagnostic pop
        ''')

        if (reaction.stp === null) {
            // Pass down the intended_tag to all input and output effects
            // downstream if the current reaction does not have a STP
            // handler.
            generateIntendedTagInheritence(body, reaction, decl, reactionIndex)
        }
    }
    
    /**
     * Return the maximum bank width for the given instantiation within all
     * instantiations of its parent reactor.
     * On the first call to this method, the breadcrumbs should be null and the max
     * argument should be zero. On recursive calls, breadcrumbs is a list of nested
     * instantiations, the max is the maximum width found so far.  The search for
     * instances of the parent reactor will begin with the last instantiation
     * in the specified list.
     * 
     * This rather complicated method is used when a reaction sends or receives data
     * to or from a bank of contained reactors. There will be an array of structs on
     * the self struct of the parent, and the size of the array is conservatively set
     * to the maximum of all the identified bank widths.  This is a bit wasteful of
     * memory, but it avoids having to malloc the array for each instance, and in
     * typical usage, there will be few instances or instances that are all the same
     * width.
     * 
     * @param containedReactor The contained reactor instantiation.
     * @param breadcrumbs null on first call (non-recursive).
     * @param max 0 on first call.
     */
    private def int maxContainedReactorBankWidth(
        Instantiation containedReactor, 
        LinkedList<Instantiation> breadcrumbs,
        int max
    ) {
        // If the instantiation is not a bank, return 1.
        if (containedReactor.widthSpec === null) {
            return 1
        }
        // If there is no main, then we just use the default width.
        if (mainDef === null) {
            return ASTUtils.width(containedReactor.widthSpec, null)
        }
        var nestedBreadcrumbs = breadcrumbs
        if (nestedBreadcrumbs === null) {
            nestedBreadcrumbs = new LinkedList<Instantiation>
            nestedBreadcrumbs.add(mainDef)
        }
        var result = max
        var parent = containedReactor.eContainer as Reactor
        if (parent == mainDef.reactorClass.toDefinition) {
            // The parent is main, so there can't be any other instantiations of it.
            return ASTUtils.width(containedReactor.widthSpec, null)
        }
        // Search for instances of the parent within the tail of the breadcrumbs list.
        val container = nestedBreadcrumbs.first.reactorClass.toDefinition
        for (instantiation: container.instantiations) {
            // Put this new instantation at the head of the list.
            nestedBreadcrumbs.add(0, instantiation)
            if (instantiation.reactorClass.toDefinition == parent) {
                // Found a matching instantiation of the parent.
                // Evaluate the original width specification in this context.
                val candidate = ASTUtils.width(containedReactor.widthSpec, nestedBreadcrumbs)
                if (candidate > result) {
                    result = candidate
                }
            } else {
                // Found some other instantiation, not the parent.
                // Search within it for instantiations of the parent.
                // Note that we assume here that the parent cannot contain
                // instances of itself.
                val candidate = maxContainedReactorBankWidth(containedReactor, nestedBreadcrumbs, result)
                if (candidate > result) {
                    result = candidate
                }
            }
            nestedBreadcrumbs.remove
        }
        return result
    }

    /** 
     * Generate code to create the trigger table for each reaction of the
     * specified reactor.  Each table lists the triggers that the reaction's
     * execution may trigger. Each table is an array of arrays
     * of pointers to the trigger_t structs representing the downstream inputs
     * (or outputs of the container reactor) that are triggered by the reaction.
     * Each trigger table goes into the reaction's reaction_t triggers field.
     * That reaction_t struct is assumed to be on the self struct of the reactor
     * instance with name "___reaction_i", where i is the index of the reaction.
     * The generated code will also set the values of the triggered_sizes array
     * on the reaction_t struct to indicate the size of each array of trigger_t
     * pointers. The generated code will malloc each of these arrays, and the
     * destructor for the reactor instance will free them.
     * The generated code goes into the __initialize_trigger_objects() function.
     * @param reactorIntance The reactor instance.
     * @param federate The federate name or null if no federation.
     */
    def generateRemoteTriggerTable(ReactorInstance reactorInstance, FederateInstance federate) {
        val selfStruct = selfStructName(reactorInstance)
        var reactionCount = 0
        for (reaction : reactorInstance.reactions) {
            if (federate === null || federate.containsReaction(
                reactorInstance.definition.reactorClass.toDefinition,
                reaction.definition
            )) {
                var Collection<PortInstance> destinationPorts = null

                var portCount = 0
                // Record the number of reactions that this reaction depends on.
                // This is used for optimization. When that number is 1, the reaction can
                // be executed immediately when its triggering reaction has completed.
                var dominatingReaction = this.reactionGraph.findSingleDominatingReaction(reaction)
                // The dominating reaction may not be included in this federate, in which case, we need to keep searching.
                while (dominatingReaction !== null 
                    && !federate.containsReaction(reactorInstance.definition.reactorClass.toDefinition, dominatingReaction.definition
                )) {
                    dominatingReaction = this.reactionGraph.findSingleDominatingReaction(dominatingReaction);
                }
                if (dominatingReaction !== null
                    && federate.containsReaction(reactorInstance.definition.reactorClass.toDefinition, dominatingReaction.definition)
                ) {
                    val upstreamReaction =
                        '''«selfStructName(dominatingReaction.parent)»->___reaction_«dominatingReaction.reactionIndex»'''
                    pr(initializeTriggerObjectsEnd, '''
                        // Reaction «reactionCount» of «reactorInstance.getFullName» depends on one maximal upstream reaction.
                        «selfStruct»->___reaction_«reactionCount».last_enabling_reaction = &(«upstreamReaction»);
                    ''')
                } else {
                    pr(initializeTriggerObjectsEnd, '''
                        // Reaction «reactionCount» of «reactorInstance.getFullName» does not depend on one maximal upstream reaction.
                        «selfStruct»->___reaction_«reactionCount».last_enabling_reaction = NULL;
                    ''')
                }
                if (targetConfig.logLevel >= LogLevel.LOG) {
                    pr(initializeTriggerObjectsEnd, '''
                        // Reaction «reactionCount» of «reactorInstance.getFullName»'s name.
                        «selfStruct»->___reaction_«reactionCount».name = "«reactorInstance.fullName» reaction «reactionCount»";
                    ''')
                }
                                
                for (port : reaction.effects.filter(PortInstance)) {
                    // Skip multiports and handle the component ports instead.
                    if (!(port instanceof MultiportInstance)) {
                        // Port is not within a multiport.
                        // The port to which the reaction writes may have dependent
                        // reactions in the container. If so, we list that port here.
                        var portsWithDependentReactions = new LinkedHashSet<PortInstance>()

                        // The size of the array to be inserted into the triggers array of
                        // the reaction is the sum of the number of destination ports and
                        // the number of destination reactions (reactions of the container
                        // sensitive to this port.
                        var numberOfTriggerTObjects = 0

                        // Collect the destinations for each output port.
                        if (port.definition instanceof Output) {
                            // For each output, obtain the destinations from the parent.
                            // Pointers to the destination trigger_t objects will be collected into
                            // an array. 
                            var parent = reactorInstance.parent
                            if (parent !== null) {
                                destinationPorts = parent.transitiveClosure(port)
                            } else {
                                // At the top level, where there cannot be any destinations
                                // for an output port.
                                destinationPorts = new LinkedList<PortInstance>()
                            }

                            // The port may also have dependent reactions, which are
                            // reactions in the container of this port's container.
                            if (port.dependentReactions.size > 0) {
                                portsWithDependentReactions.add(port)
                                numberOfTriggerTObjects += port.dependentReactions.size
                            }
                        } else {
                            // The port is the input port of a contained reactor,
                            // use that reactor instance to compute the transitive closure.
                            destinationPorts = port.parent.transitiveClosure(port)
                        }

                        numberOfTriggerTObjects += destinationPorts.size

                        // Record this array size in reaction's reaction_t triggered_sizes array.
                        pr(initializeTriggerObjectsEnd, '''
                            // Reaction «reactionCount» of «reactorInstance.getFullName» triggers «numberOfTriggerTObjects»
                            // downstream reactions through port «port.getFullName».
                            «selfStruct»->___reaction_«reactionCount».triggered_sizes[«portCount»] = «numberOfTriggerTObjects»;
                        ''')
                        if (numberOfTriggerTObjects > 0) {
                            // Next, malloc the memory for the trigger array and record its location.
                            // NOTE: Need a unique name for the pointer to the malloc'd array because some of the
                            // initialization has to occur at the end of __initialize_trigger_objects(), after
                            // all reactor instances have been created.
                            var bankIndex = ""
                            if (reactorInstance.bankIndex >= 0) {
                                bankIndex = '_' + reactorInstance.bankIndex + '_'
                            }
                            val triggerArray = '''«reactorInstance.uniqueID»«bankIndex»_«reaction.reactionIndex»_«portCount»'''
                            pr(initializeTriggerObjectsEnd, '''
                                // For reaction «reactionCount» of «reactorInstance.getFullName», allocate an
                                // array of trigger pointers for downstream reactions through port «port.getFullName»
                                trigger_t** «triggerArray» = (trigger_t**)malloc(«numberOfTriggerTObjects» * sizeof(trigger_t*));
                                «selfStruct»->___reaction_«reactionCount».triggers[«portCount»] = «triggerArray»;
                            ''')

                            // Next, initialize the newly created array.
                            var destinationCount = 0;
                            for (destination : destinationPorts) {
                                // If the destination of a connection is an input
                                // port of a reactor that has no reactions to that input,
                                // then this trigger struct will not have been created.
                                // In that case, we want NULL.
                                // If the destination is an output port, however, then
                                // the dependentReactions.size reflects the number of downstream
                                // reactions, including possible reactions in the container.
                                if (destination.isOutput) {
                                    if (destination.dependentReactions.size === 0) {
                                        pr(initializeTriggerObjectsEnd, '''
                                            // Destination port «destination.getFullName» itself has no reactions.
                                            «triggerArray»[«destinationCount++»] = NULL;
                                        ''')
                                    } else {
                                        // Add to portsWithDependentReactions. This occurs if the destination is
                                        // output port of the container, and that output port triggers reactions in
                                        // its container.
                                        portsWithDependentReactions.add(destination)
                                    }
                                } else if (destination.dependentReactions.size === 0) {
                                    pr(initializeTriggerObjectsEnd, '''
                                        // Destination port «destination.getFullName» itself has no reactions.
                                        «triggerArray»[«destinationCount++»] = NULL;
                                    ''')
                                } else if (!(destination instanceof MultiportInstance)) { // Skip multiports.
                                                                        // Instead, the component ports are handled.
                                    pr(initializeTriggerObjectsEnd, '''
                                        // Point to destination port «destination.getFullName»'s trigger struct.
                                        «triggerArray»[«destinationCount++»] = &«triggerStructName(destination)»;
                                    ''')
                                }
                            }
                            for (portWithDependentReactions : portsWithDependentReactions) {
                                for (destinationReaction : portWithDependentReactions.dependentReactions) {
                                    if (reactorBelongsToFederate(destinationReaction.parent, federate)) {
                                        pr(initializeTriggerObjectsEnd, '''
                                            // Port «port.getFullName» has reactions in its parent's parent.
                                            // Point to the trigger struct for those reactions.
                                            «triggerArray»[«destinationCount++»] = &«triggerStructName(portWithDependentReactions, destinationReaction)»;
                                        ''')
                                    }
                                }
                            }
                        }
                        portCount++
                    }
                }
            }
            // Increment reaction count even if it is not in the federate for consistency.
            reactionCount++
        }
    }

    /** 
     * Generate code to set up the tables used in __start_time_step to decrement reference
     * counts and mark outputs absent between time steps. This function puts the code
     * into startTimeStep.
     */
    def generateStartTimeStep(ReactorInstance instance, FederateInstance federate) {
        // First, set up to decrement reference counts for each token type
        // input of a contained reactor that is present.
        for (child : instance.children) {
            if (reactorBelongsToFederate(child, federate)) {
                var nameOfSelfStruct = selfStructName(child)
                for (input : child.inputs) {
                    if (isTokenType((input.definition as Input).inferredType)) {
                        if (input instanceof MultiportInstance) {
                            pr(startTimeStep, '''
                                for (int i = 0; i < «input.width»; i++) {
                                    __tokens_with_ref_count[«startTimeStepTokens» + i].token
                                            = &«nameOfSelfStruct»->__«input.name»[i]->token;
                                    __tokens_with_ref_count[«startTimeStepTokens» + i].status
                                            = (port_status_t*)&«nameOfSelfStruct»->__«input.name»[i]->is_present;
                                    __tokens_with_ref_count[«startTimeStepTokens» + i].reset_is_present = false;
                                }
                            ''')
                            startTimeStepTokens += input.width
                        } else {
                            pr(startTimeStep, '''
                                __tokens_with_ref_count[«startTimeStepTokens»].token
                                        = &«nameOfSelfStruct»->__«input.name»->token;
                                __tokens_with_ref_count[«startTimeStepTokens»].status
                                        = (port_status_t*)&«nameOfSelfStruct»->__«input.name»->is_present;
                                __tokens_with_ref_count[«startTimeStepTokens»].reset_is_present = false;
                            ''')
                            startTimeStepTokens++
                        }
                    }
                }
            }
        }
        var containerSelfStructName = selfStructName(instance)
        // Handle inputs that get sent data from a reaction rather than from
        // another contained reactor and reactions that are triggered by an
        // output of a contained reactor.
        // Note that there may be more than one reaction reacting to the same
        // port so we have to avoid listing the port more than once.
        val portsSeen = new LinkedHashSet<PortInstance>();
        for (reaction : instance.reactions) {
            if (federate === null || federate.containsReaction(
                instance.definition.reactorClass.toDefinition,
                reaction.definition
            )) {
                for (port : reaction.effects.filter(PortInstance)) {
                    // Skip any actual multiports if they are listed. Only count the individual ports.
                    if (port.definition instanceof Input  && !(port instanceof MultiportInstance)) {
                        // This reaction is sending to an input. Must be
                        // the input of a contained reactor in the federate.
                        val sourcePort = sourcePort(port)
                        if (reactorBelongsToFederate(sourcePort.parent, federate)) {
                            // If this is a multiport, then the port struct on the self
                            // struct is a pointer. Otherwise, it is the struct itself.
                            var multiportIndex = stackStructOperator // '.'
                            if (sourcePort.multiportIndex >= 0) {
                                multiportIndex = '[' + sourcePort.multiportIndex + ']->'
                            }
                            pr(startTimeStep, '''
                                // Add port «sourcePort.getFullName» to array of is_present fields.
                                __is_present_fields[«startTimeStepIsPresentCount»] 
                                        = &«containerSelfStructName»->__«sourcePort.parent.name».«sourcePort.name»«multiportIndex»is_present;
                            ''')
                            if (isFederatedAndDecentralized) {
                                // Intended_tag is only applicable to ports in federated execution.
                                pr(startTimeStep, '''
                                    // Add port «sourcePort.getFullName» to array of is_present fields.
                                    __intended_tag_fields[«startTimeStepIsPresentCount»] 
                                            = &«containerSelfStructName»->__«sourcePort.parent.name».«sourcePort.name»«multiportIndex»intended_tag;
                                ''')
                            }
                            startTimeStepIsPresentCount++
                        }
                    }
                }
                // Find outputs of contained reactors that have token types and therefore
                // need to have their reference counts decremented.
                for (port : reaction.sources) {
                    if (port.definition instanceof Output && !portsSeen.contains(port)) {
                        portsSeen.add(port as PortInstance)
                        // This reaction is receiving data from the port.
                        if (isTokenType((port.definition as Output).inferredType)) {
                            if (port instanceof MultiportInstance) {
                                pr(startTimeStep, '''
                                    for (int i = 0; i < «port.width»; i++) {
                                        __tokens_with_ref_count[«startTimeStepTokens» + i].token
                                                = &«containerSelfStructName»->__«port.parent.name».«port.name»[i]->token;
                                        __tokens_with_ref_count[«startTimeStepTokens» + i].status
                                                = (port_status_t*)&«containerSelfStructName»->__«port.parent.name».«port.name»[i]->is_present;
                                        __tokens_with_ref_count[«startTimeStepTokens» + i].reset_is_present = false;
                                    }
                                ''')
                                startTimeStepTokens += port.width
                            } else {
                                pr(startTimeStep, '''
                                    __tokens_with_ref_count[«startTimeStepTokens»].token
                                            = &«containerSelfStructName»->__«port.parent.name».«port.name»->token;
                                    __tokens_with_ref_count[«startTimeStepTokens»].status
                                            = (port_status_t*)&«containerSelfStructName»->__«port.parent.name».«port.name»->is_present;
                                    __tokens_with_ref_count[«startTimeStepTokens»].reset_is_present = false;
                                ''')
                                startTimeStepTokens++
                            }
                        }
                    }
                }
            }
        }
        // Next, set up the table to mark each output of each contained reactor absent.
        for (child : instance.children) {
            if (reactorBelongsToFederate(child, federate)) {
                var nameOfSelfStruct = selfStructName(child)
                for (output : child.outputs) {
                    if (output instanceof MultiportInstance) {
                        var j = 0
                        for (multiportInstance : output.instances) {
                            pr(startTimeStep, '''
                                // Add port «output.getFullName» to array of is_present fields.
                                __is_present_fields[«startTimeStepIsPresentCount»] = &«nameOfSelfStruct»->«getStackPortMember('''__«output.name»[«j»]''', "is_present")»;
                            ''')
                            if (isFederatedAndDecentralized) {
                                // Intended_tag is only applicable to ports in federated execution with decentralized coordination.
                                pr(startTimeStep, '''
                                    // Add port «output.getFullName» to array of intended_tag fields.
                                    __intended_tag_fields[«startTimeStepIsPresentCount»] = &«nameOfSelfStruct»->«getStackPortMember('''__«output.name»[«j»]''', "intended_tag")»;
                                ''')
                            }
                            startTimeStepIsPresentCount++
                            j++
                        }
                    } else {
                        pr(startTimeStep, '''
                            // Add port «output.getFullName» to array of is_present fields.
                            __is_present_fields[«startTimeStepIsPresentCount»] = &«nameOfSelfStruct»->«getStackPortMember('''__«output.name»''', "is_present")»;
                        ''')
                        if (isFederatedAndDecentralized) {                            
                            // Intended_tag is only applicable to ports in federated execution with decentralized coordination.
                            pr(startTimeStep, '''
                                // Add port «output.getFullName» to array of Intended_tag fields.
                                __intended_tag_fields[«startTimeStepIsPresentCount»] = &«nameOfSelfStruct»->«getStackPortMember('''__«output.name»''', "intended_tag")»;
                            ''')                            
                        }
                        startTimeStepIsPresentCount++
                    }
                }
            }
        }
        for (action : instance.actions) {
            pr(startTimeStep, '''
                // Add action «action.getFullName» to array of is_present fields.
                __is_present_fields[«startTimeStepIsPresentCount»] 
                        = &«containerSelfStructName»->__«action.name».is_present;
            ''')
            if (isFederatedAndDecentralized) {
                // Intended_tag is only applicable to actions in federated execution with decentralized coordination.
                pr(startTimeStep, '''
                    // Add action «action.getFullName» to array of intended_tag fields.
                    __intended_tag_fields[«startTimeStepIsPresentCount»] 
                            = &«containerSelfStructName»->__«action.name».intended_tag;
                ''')
            }
            startTimeStepIsPresentCount++
        }
    }
    
    /**
     * For each timer and action in the specified reactor instance, generate
     * initialization code for the offset and period fields. This code goes into
     * __initialize_trigger_objects(). This has to be done separately for each
     * instance, rather than by the constructor, because the values of the offset
     * and period may be given by parameters, so the values are potentially
     * different for each instance.
     * 
     * This method will also populate the global __timer_triggers array, which is
     * used to start all timers at the start of execution.
     * 
     * @param reactorInstance The instance for which we are generating trigger objects.
     * @return A map of trigger names to the name of the trigger struct.
     */
    def generateOffsetAndPeriodInitializations(ReactorInstance reactorInstance) {
        var count = 0
        // Iterate over triggers (input ports, actions, and timers that trigger reactions).
        for (triggerInstance : reactorInstance.triggersAndReads) {
            var trigger = triggerInstance.definition
            var triggerStructName = triggerStructName(triggerInstance)
            if (trigger instanceof Timer && !triggerInstance.isStartup) {
                val offset = timeInTargetLanguage((triggerInstance as TimerInstance).offset)
                val period = timeInTargetLanguage((triggerInstance as TimerInstance).period)
                pr(initializeTriggerObjects, '''
                    «triggerStructName».offset = «offset»;
                    «triggerStructName».period = «period»;
                    __timer_triggers[«timerCount»] = &«triggerStructName»;
                ''')
                timerCount++
            } else if (trigger instanceof Action && !triggerInstance.isShutdown) {
                var minDelay = (triggerInstance as ActionInstance).minDelay
                var minSpacing = (triggerInstance as ActionInstance).minSpacing
                pr(initializeTriggerObjects, '''
                    «triggerStructName».offset = «timeInTargetLanguage(minDelay)»;
                    «IF minSpacing !== null»
                    «triggerStructName».period = «timeInTargetLanguage(minSpacing)»;
                    «ELSE»
                    «triggerStructName».period = «CGenerator.UNDEFINED_MIN_SPACING»;
                    «ENDIF»
                ''')               
            } else {
                // The trigger is either a port or a startup or shutdown trigger.
                // Nothing to do in initialize_trigger_objects
            }
            count++
            triggerCount++
        }
    }

    /**
     * Process a given .proto file.
     * 
     * Run, if possible, the proto-c protocol buffer code generator to produce
     * the required .h and .c files.
     * @param filename Name of the file to process.
     */
     def processProtoFile(String filename) {
        val protoc = createCommand(
            "protoc-c",
            #['''--c_out=«this.fileConfig.getSrcGenPath»''', filename],
            fileConfig.srcPath,
            "Processing .proto files requires proto-c >= 1.3.3.",
            true)
        if (protoc === null) {
            return
        }
        val returnCode = protoc.executeCommand()
        if (returnCode == 0) {
            val nameSansProto = filename.substring(0, filename.length - 6)
            targetConfig.compileAdditionalSources.add(this.fileConfig.getSrcGenPath.resolve(nameSansProto + ".pb-c.c").toString)

            targetConfig.compileLibraries.add('-l')
            targetConfig.compileLibraries.add('protobuf-c')    
        } else {
            reportError("protoc-c returns error code " + returnCode)
        }
    }
    
    /**
     * Return a string that defines the log level.
     */
    static def String defineLogLevel(GeneratorBase generator) {
        // FIXME: if we align the levels with the ordinals of the
        // enum (see CppGenerator), then we don't need this function.
        switch(generator.targetConfig.logLevel) {
            case ERROR: '''
                #define LOG_LEVEL 0
            '''
            case WARN: '''
                #define LOG_LEVEL 1
            '''
            case INFO: '''
                #define LOG_LEVEL 2
            ''' 
            case LOG: '''
                #define LOG_LEVEL 3
            '''
            case DEBUG: '''
                #define LOG_LEVEL 4
            '''
        }
    }
    
    /**
     * Return a string for referencing the struct with the value and is_present
     * fields of the specified port. This is used for establishing the destination of
     * data for a connection between ports.
     * This will have one of the following forms:
     * 
     * * selfStruct->__portName
     * * selfStruct->__portName[i]
     * 
     * @param port An instance of a destination input port.
     */
    static def destinationReference(PortInstance port) {
        var destStruct = selfStructName(port.parent)

        // If the destination is in a multiport, find its index.
        var destinationIndexSpec = ''
        if (port.multiportIndex >= 0) {
            destinationIndexSpec = '[' + port.multiportIndex + ']'
        }
                
        if (port.isInput) {
            return '''«destStruct»->__«port.name»«destinationIndexSpec»'''
        } else {
            throw new Exception("INTERNAL ERROR: destinationReference() should only be called on input ports.")
        }        
    }
 
    /**
     * Return a string for referencing the port struct with the value
     * and is_present fields in a self struct that receives data from
     * the specified output port to be used by a reaction.
     * The output port is contained by a contained reactor.
     * This will have one of the following forms:
     * 
     * * selfStruct->__reactorName.portName
     * * selfStruct->__reactorName.portName[i]
     * 
     * The selfStruct is that of the container of reactor that
     * contains the port. If the port is in a multiport, then i is
     * the index of the port within the multiport.
     * 
     * @param port An instance of a destination port.
     */
    static def reactionReference(PortInstance port) {
         var destStruct = selfStructName(port.parent.parent)

        // If the destination is in a multiport, find its index.
        var destinationIndexSpec = ''
        if (port.multiportIndex >= 0) {
            destinationIndexSpec = '[' + port.multiportIndex + ']'
        }
                
        if (port.isOutput) {
            return '''«destStruct»->__«port.parent.name».«port.name»«destinationIndexSpec»'''
        } else {
            return '// Nothing to do. Port is an input.'
        }
    }
 
    /**
     * Return a string for referencing the data or is_present value of
     * the specified port. This is used for establishing the source of
     * data for a connection between ports.
     * This will have one of the following forms:
     * 
     * * &selfStruct->__portName
     * * &selfStruct->__parentName.portName
     * * &selfStruct->__portName[i]
     * * selfStruct->__parentName.portName[i]
     * 
     * If the port depends on another port, then this will reference
     * the eventual upstream port where the data is store. E.g., it is an input that
     * connected to upstream output, then portName will be the name
     * of the upstream output and the selfStruct will be that of the
     * upstream reactor. If the port is an input port that is written to
     * by a reaction of the parent of the port's parent, then the selfStruct
     * will be that of the parent of the port's parent, and parentName
     * will the name of the port's parent.
     * If the port is an output, then selfStruct will be the parent's
     * selfStruct and the portName will be the name of the port.
     * If the port is a multiport, then one of the last two forms will
     * be used, where i is the index of the multiport.
     * 
     * @param port An instance of the port to be referenced.
     */
    static def sourceReference(PortInstance port) {
        // If the port depends on another port, find the ultimate source port,
        // which could be the input port if it is written to by a reaction
        // or it could be an upstream output port. 
        var eventualSource = sourcePort(port)
        
        // If it is in a multiport, find its index.          
        var sourceIndexSpec = ''
        var indirection = '&'
        if (eventualSource.multiportIndex >= 0) {
            sourceIndexSpec = '[' + eventualSource.multiportIndex + ']'
            if (eventualSource.isInput) {
                indirection = ''
            }
        }
                
        if (eventualSource.isOutput) {
            val sourceStruct = selfStructName(eventualSource.parent)
            return '''«indirection»«sourceStruct»->__«eventualSource.name»«sourceIndexSpec»'''
        } else {
            val sourceStruct = selfStructName(eventualSource.parent.parent)
            return '''«indirection»«sourceStruct»->__«eventualSource.parent.name».«eventualSource.name»«sourceIndexSpec»'''
        }
    }

    /** Return the unique name for the "self" struct of the specified
     *  reactor instance from the instance ID. If the instance is a member
     *  of a bank of reactors, this returns something of the form
     *  name_self[index], where the index is the position within the bank.
     *  @param instance The reactor instance.
     *  @return The name of the self struct.
     */
    static def selfStructName(ReactorInstance instance) {
        var result = instance.uniqueID + "_self"
        // If this reactor is a member of a bank of reactors, then change
        // the name of its self struct to append [index].
        if (instance.bankIndex >= 0) {
            result += "[" + instance.bankIndex + "]"
        }
        return result
    }

    /** Construct a unique type for the "self" struct of the specified
     *  reactor class from the reactor class.
     *  @param reactor The reactor class.
     *  @return The name of the self struct.
     */
    def selfStructType(ReactorDecl reactor) {
        return reactor.name.toLowerCase + "_self_t"
    }
    
    /** Construct a unique type for the struct of the specified
     *  typed variable (port or action) of the specified reactor class.
     *  @param variable The variable.
     *  @param reactor The reactor class.
     *  @return The name of the self struct.
     */
    def variableStructType(Variable variable, ReactorDecl reactor) {
        '''«reactor.name.toLowerCase»_«variable.name»_t'''
    }
    
    /** Return the function name for specified reaction of the
     *  specified reactor.
     *  @param reactor The reactor
     *  @param reactionIndex The reaction index.
     *  @return The function name for the reaction.
     */
    def reactionFunctionName(ReactorDecl reactor, int reactionIndex) {
          reactor.name.toLowerCase + "reaction_function_" + reactionIndex
    }

    /** Return a reference to the trigger_t struct of the specified
     *  trigger instance (input port or action). This trigger_t struct
     *  is on the self struct.
     *  @param instance The port or action instance.
     *  @return The name of the trigger struct.
     */
    static def triggerStructName(TriggerInstance<? extends Variable> instance) {
        return selfStructName(instance.parent) 
                + '->___'
                + instance.name
    }
    
    /** Return a reference to the trigger_t struct for the specified output
     *  port of a contained reactor that triggers the specified reaction.
     *  @param port The output port of a contained reactor.
     *  @param reaction The reaction triggered by this port.
     *  @return The name of the trigger struct, which is in the self struct
     *   of the container of the reaction.
     */
    static def triggerStructName(PortInstance port, ReactionInstance reaction) {
        return '''«selfStructName(reaction.parent)»->__«port.parent.name».«port.name»_trigger;'''
    }
    
    /**
     * Generates C code to retrieve port->member
     * This function is used for clarity and is called whenever struct is allocated on heap memory.
     * @param portName The name of the port in string
     * @param member The member's name (e.g., is_present)
     * @return Generated code
     */
    def getHeapPortMember(String portName, String member) '''
        «portName»->«member»
    '''
    
    
    /**
     * Return the operator used to retrieve struct members
     */
    def getStackStructOperator() '''
    .
    '''
    
    /**
     * Generates C code to retrieve port.member
     * This function is used for clarity and is called whenever struct is allocated on stack memory.
     * @param portName The name of the port in string
     * @param member The member's name(e.g., is_present)
     * @return Generated code
     */
    def getStackPortMember(String portName, String member) '''
        «portName».«member»
    '''
    /**
     * Return the full name of the specified instance without
     * the leading name of the top-level reactor, unless this
     * is the top-level reactor, in which case return its name.
     * @param instance The instance.
     * @return A shortened instance name.
     */
    def getShortenedName(ReactorInstance instance) {
        var description = instance.getFullName
        // If not at the top level, strip off the name of the top level.
        val period = description.indexOf(".")
        if (period > 0) {
            description = description.substring(period + 1)
        }
        return description
    }
    
    /**
     * If tracing is turned on, then generate code that records
     * the full name of the specified reactor instance in the
     * trace table. If tracing is not turned on, do nothing.
     * @param instance The reactor instance.
     * @param builder The place to put the generated code.
     */
    def void generateTraceTableEntries(ReactorInstance instance, StringBuilder builder) {
        // If tracing is turned on, record the address of this reaction
        // in the _lf_trace_object_descriptions table that is used to generate
        // the header information in the trace file.
        if (targetConfig.tracing !== null) {
            var description = getShortenedName(instance)
            var nameOfSelfStruct = selfStructName(instance)
            pr(builder, '''
                _lf_register_trace_event(«nameOfSelfStruct», NULL, trace_reactor, "«description»");
            ''')
            for (action : instance.actions) {
                pr(builder, '''
                    _lf_register_trace_event(«nameOfSelfStruct», &(«nameOfSelfStruct»->___«action.name»), trace_trigger, "«description».«action.name»");
                ''')
            }
            for (timer : instance.timers) {
                pr(builder, '''
                    _lf_register_trace_event(«nameOfSelfStruct», &(«nameOfSelfStruct»->___«timer.name»), trace_trigger, "«description».«timer.name»");
                ''')
            }
        }
    } 

    /** 
     * Generate code to instantiate the specified reactor instance and
     * initialize it.
     * @param instance A reactor instance.
     * @param federate A federate instance to conditionally generate code by
     *  contained reactors or null if there are no federates.
     */
    def void generateReactorInstance(ReactorInstance instance, FederateInstance federate) {
        // If this is not the main reactor and is not in the federate, nothing to do.
        if (instance !== this.main && !reactorBelongsToFederate(instance, federate)) {
            return
        }
        var reactorClass = instance.definition.reactorClass
        var fullName = instance.fullName
        pr(initializeTriggerObjects, '// ************* Instance ' + fullName + ' of class ' +
            reactorClass.name)
            
        var nameOfSelfStruct = selfStructName(instance)
        var structType = selfStructType(reactorClass)
        
        // If this reactor is a placeholder for a bank of reactors, then generate
        // an array of instances of reactors and return.
        if (instance.bankMembers !== null) {
            pr(initializeTriggerObjects, '''
                «structType»* «nameOfSelfStruct»[«instance.bankMembers.size»];
            ''')
            return
        }

        // If this reactor is an instance in a bank of federates, then only generate an
        // instance if the bank index of the reactor matches the bank index of the federate.
        if (federate.instantiation === instance.definition    // Is a top-level federate.
            && federate.instantiation.widthSpec !== null      // Is in a bank of federates.
            && federate.bankIndex != instance.bankIndex    // Bank position does not match.
        ) {
            return;
        }

        // Generate the instance self struct containing parameters, state variables,
        // and outputs (the "self" struct). The form is slightly different
        // depending on whether its in a bank of reactors.
        if (instance.bankIndex >= 0) {
            pr(initializeTriggerObjects, '''
                «nameOfSelfStruct» = new_«reactorClass.name»();
            ''')
            // Set the bankIndex for the reactor
            pr(initializeTriggerObjectsEnd, '''
                «nameOfSelfStruct»->«targetBankIndex» = «instance.bankIndex»;
            ''')
        } else {
            pr(initializeTriggerObjects, '''
                «structType»* «nameOfSelfStruct» = new_«reactorClass.name»();
            ''')
            // Set the bankIndex to zero
            pr(initializeTriggerObjectsEnd, '''
                «nameOfSelfStruct»->«targetBankIndex» = 0;
            ''')
        }
        
        generateTraceTableEntries(instance, initializeTriggerObjects)
              
        generateReactorInstanceExtension(initializeTriggerObjects, instance, federate)

        // Generate code to initialize the "self" struct in the
        // __initialize_trigger_objects function.
        pr(initializeTriggerObjects, "//***** Start initializing " + fullName)

        // Start with parameters.
        generateParameterInitialization(initializeTriggerObjects, instance)
        
        // Once parameters are done, we can allocate memory for any multiports.
        // Allocate memory for outputs.
        for (output : reactorClass.toDefinition.outputs) {
            // If the port is a multiport, create an array.
            if (output.isMultiport) {
                initializeOutputMultiport(initializeTriggerObjects, output, nameOfSelfStruct, instance)
            } else {
                pr(initializeTriggerObjects, '''
                    // width of -2 indicates that it is not a multiport.
                    «nameOfSelfStruct»->__«output.name»__width = -2;
                ''')
            }
        }

        // For each reaction instance, allocate the arrays that will be used to
        // trigger downstream reactions.
        // Avoid allocating more than once (in case a port is in the
        // effects field of more than once reactor).
        val portAllocatedAlready = new LinkedHashSet<PortInstance>()
        var reactionCount = 0
        for (reaction : instance.reactions) {
            if (federate === null || federate.containsReaction(reactorClass.toDefinition, reaction.definition)) {
                generateReactionOutputs(reaction, portAllocatedAlready);

                // Next handle triggers of the reaction that come from a multiport output
                // of a contained reactor.  Also, handle startup and shutdown triggers.
                // FIXME: This does not handle triggers that come from a contained bank of reactors.
                for (trigger : reaction.triggers) {
                    if (trigger instanceof PortInstance) {
                        // If the port is a multiport, then we need to create an entry for each
                        // individual port.
                        if (trigger instanceof MultiportInstance && trigger.parent !== null && trigger.isOutput) {
                            // If the width is given as a numeric constant, then add that constant
                            // to the output count. Otherwise, assume it is a reference to one or more parameters.
                            val width = (trigger as MultiportInstance).width;
                            val containerName = trigger.parent.name
                            val portStructType = variableStructType(trigger.definition,
                                trigger.parent.definition.reactorClass)

                            pr(initializeTriggerObjectsEnd, '''
                                «nameOfSelfStruct»->__«containerName».«trigger.name»__width = «width»;
                                // Allocate memory to store pointers to the multiport outputs of a contained reactor.
                                «nameOfSelfStruct»->__«containerName».«trigger.name» = («portStructType»**)malloc(sizeof(«portStructType»*) 
                                        * «nameOfSelfStruct»->__«containerName».«trigger.name»__width);
                            ''')
                        }
                    }
                    if (trigger.isStartup) {
                        pr(initializeTriggerObjects, '''
                            __startup_reactions[«startupReactionCount++»] = &«nameOfSelfStruct»->___reaction_«reactionCount»;
                        ''')
                    } else if (trigger.isShutdown) {
                        pr(initializeTriggerObjects, '''
                            __shutdown_reactions[«shutdownReactionCount++»] = &«nameOfSelfStruct»->___reaction_«reactionCount»;
                        ''')

                        if (targetConfig.tracing !== null) {
                            val description = getShortenedName(instance)
                            pr(initializeTriggerObjects, '''
                                _lf_register_trace_event(«nameOfSelfStruct», &(«nameOfSelfStruct»->___shutdown),
                                        trace_trigger, "«description».shutdown");
                            ''')
                        }
                    }
                }
            }
            // Increment the reactionCount even if the reaction is not in the federate
            // so that reaction indices are consistent across federates.
            reactionCount++
        }
        
        // Next, allocate memory for input. 
        for (input : reactorClass.toDefinition.inputs) {
            // If the port is a multiport, create an array.
            if (input.isMultiport) {
                pr(initializeTriggerObjects, '''
                    «nameOfSelfStruct»->__«input.name»__width = «multiportWidthSpecInC(input, null, instance)»;
                    // Allocate memory for multiport inputs.
                    «nameOfSelfStruct»->__«input.name» = («variableStructType(input, reactorClass)»**)malloc(sizeof(«variableStructType(input, reactorClass)»*) * «nameOfSelfStruct»->__«input.name»__width); 
                    // Set inputs by default to an always absent default input.
                    for (int i = 0; i < «nameOfSelfStruct»->__«input.name»__width; i++) {
                        «nameOfSelfStruct»->__«input.name»[i] = &«nameOfSelfStruct»->__default__«input.name»;
                    }
                ''')
            } else {
                pr(initializeTriggerObjects, '''
                    // width of -2 indicates that it is not a multiport.
                    «nameOfSelfStruct»->__«input.name»__width = -2;
                ''')
            }            
        }

        // Next, initialize the "self" struct with state variables.
        // These values may be expressions that refer to the parameter values defined above.        
        generateStateVariableInitializations(instance)

        // Generate reaction structs for the instance.
        generateRemoteTriggerTable(instance, federate)

        // Generate trigger objects for the instance.
        generateOffsetAndPeriodInitializations(instance)

        // Next, set the number of destinations,
        // which is used to initialize reference counts.
        // Reference counts are decremented by each destination reactor
        // at the conclusion of a time step. Hence, the initial reference
        // count should equal the number of destination _reactors_, not the
        // number of destination ports nor the number of destination reactions.
        // One of the destination reactors may be the container of this
        // instance because it may have a reaction to an output of this instance. 
        for (output : instance.outputs) {
            if (output instanceof MultiportInstance) {
                var j = 0
                for (multiportInstance : output.instances) {
                    var numDestinations = multiportInstance.numDestinationReactors
                    pr(initializeTriggerObjectsEnd, '''
                        «nameOfSelfStruct»->«getStackPortMember('''__«output.name»[«j»]''', "num_destinations")» = «numDestinations»;
                    ''')
                    j++
                }
            } else {
                var numDestinations = output.numDestinationReactors
                pr(initializeTriggerObjectsEnd, '''
                    «nameOfSelfStruct»->«getStackPortMember('''__«output.name»''', "num_destinations")» = «numDestinations»;
                ''')
            }
            
        }
        
        // Do the same for inputs of contained reactors that are sent data by reactions
        // of this reactor.
        for (reaction : instance.reactions) {
            if (federate === null || federate.containsReaction(
                instance.definition.reactorClass.toDefinition,
                reaction.definition
            )) {
                // Handle reactions that produce outputs sent to inputs
                // of contained reactors.  An input port can have only
                // one source, so we can immediately generate the initialization.
                for (port : reaction.effects.filter(PortInstance)) {
                    // Skip multiport destinations and instead handle the ports within the multiport.
                    if (port.isInput && !(port instanceof MultiportInstance)) {
                        var numDestinations = 0
                        if(!port.dependentReactions.isEmpty) numDestinations = 1
                        numDestinations += port.dependentPorts.size
                        // If it is a multiport, then the struct port object is a pointer.
                        // Otherwise, it is the actual port struct.
                        var portIndex = stackStructOperator // '.'
                        if (port.multiportIndex >= 0) {
                            portIndex = '[' + port.multiportIndex + ']->'
                        }
                        pr(initializeTriggerObjectsEnd, '''
                            «nameOfSelfStruct»->__«port.parent.name».«port.name»«portIndex»num_destinations = «numDestinations»;
                        ''')
                    }
                }
            }
        }

        // Next, initialize actions by creating a lf_token_t in the self struct.
        // This has the information required to allocate memory for the action payload.
        // Skip any action that is not actually used as a trigger.
        val triggersInUse = instance.triggers
        for (action : instance.actions) {
            // Skip this step if the action is not in use. 
            if (triggersInUse.contains(action)) {
                var type = (action.definition as Action).inferredType
                var payloadSize = "0"
                
                if (!type.isUndefined) {
                    var String typeStr = type.targetType
                    if (isTokenType(type)) {
                        typeStr = typeStr.rootType
                    } else {
                        typeStr = type.targetType
                    }
                    if (typeStr !== null && !typeStr.equals("") && !typeStr.equals("void")) {
                        payloadSize = '''sizeof(«typeStr»)'''
                    }    
                }
            
                // Create a reference token initialized to the payload size.
                // This token is marked to not be freed so that the trigger_t struct
                // always has a reference token.
                pr(initializeTriggerObjects,
                    '''
                    «nameOfSelfStruct»->___«action.name».token = __create_token(«payloadSize»);
                    «nameOfSelfStruct»->___«action.name».status = absent;
                    '''
                )
                // At the start of each time step, we need to initialize the is_present field
                // of each action's trigger object to false and free a previously
                // allocated token if appropriate. This code sets up the table that does that.
                pr(initializeTriggerObjects, '''
                    __tokens_with_ref_count[«startTimeStepTokens»].token
                            = &«nameOfSelfStruct»->___«action.name».token;
                    __tokens_with_ref_count[«startTimeStepTokens»].status
                            = &«nameOfSelfStruct»->___«action.name».status;
                    __tokens_with_ref_count[«startTimeStepTokens»].reset_is_present = true;
                ''')
                startTimeStepTokens++
            }
        }
        // Handle reaction local deadlines.
        reactionCount = 0
        for (reaction : instance.reactions) {
            if (federate === null || federate.containsReaction(
                instance.definition.reactorClass.toDefinition,
                reaction.definition
            )) {
                if (reaction.declaredDeadline !== null) {
                    var deadline = reaction.declaredDeadline.maxDelay
                    val reactionStructName = '''«selfStructName(reaction.parent)»->___reaction_«reactionCount»'''
                    pr(initializeTriggerObjects, '''
                        «reactionStructName».deadline = «timeInTargetLanguage(deadline)»;
                    ''')
                }
            }
            // Increment the reaction count even if not in the federate for consistency.
            reactionCount++;
        }
        for (child : instance.children) {
            if (reactorBelongsToFederate(child, federate)) {
                generateReactorInstance(child, federate)
            }
        }
        
        // If this program is federated with centralized coordination and this reactor
        // instance is a federate, then check
        // for outputs that depend on physical actions so that null messages can be
        // sent to the RTI.
        if (isFederatedAndCentralized && instance.definition === federate.instantiation) {
            val outputDelayMap = federate.findOutputsConnectedToPhysicalActions(instance)
            var minDelay = TimeValue.MAX_VALUE;
            var outputFound = null as Output;
            for (output : outputDelayMap.keySet) {
                val outputDelay = outputDelayMap.get(output)
                if (outputDelay.isEarlierThan(minDelay)) {
                    minDelay = outputDelay
                    outputFound = output
                }
            }
            if (minDelay != TimeValue.MAX_VALUE) {
                // Unless silenced, issue a warning.
                if (targetConfig.coordinationOptions.advance_message_interval === null) {
                    reportWarning(outputFound, '''
                            Found a path from a physical action to output for reactor "«instance.name»". 
                            The amount of delay is «minDelay.toString()».
                            With centralized coordination, this can result in a large number of messages to the RTI.
                            Consider refactoring the code so that the output does not depend on the physical action,
                            or consider using decentralized coordination. To silence this warning, set the target
                            parameter cooridiation-options with a value like {advance-message-interval: 10 msec}"''')
                }
                pr(initializeTriggerObjects, '''
                    _fed.min_delay_from_physical_action_to_federate_output = «minDelay.timeInTargetLanguage»;
                ''')
            }
        }
        
        // For this instance, define what must be done at the start of
        // each time step. This sets up the tables that are used by the
        // __start_time_step() function in reactor_common.c.
        // Note that this function is also run once at the end
        // so that it can deallocate any memory.
        generateStartTimeStep(instance, federate)
        pr(initializeTriggerObjects, "//***** End initializing " + fullName)
    }
    
    /**
     * For the specified reaction, for output ports that it writes to,
     * set up the arrays that store the output values (if necessary) and
     * that are used to trigger downstream reactions if an output is actually
     * produced.
     * 
     * NOTE: This method is quite complicated because of the possibility that
     * that the reaction is writing to a multiport output or to an
     * input port of a contained reactor, and the possibility that that
     * the contained reactor is a bank of reactors and that its input port may
     * be a multiport.
     * 
     * @param The reaction instance.
     * @param portAllocatedAlready A set of ports that have already had memory allocated by previous reactions.
     */
    private def void generateReactionOutputs(
        ReactionInstance reaction, 
        LinkedHashSet<PortInstance> portAllocatedAlready
    ) {
        val nameOfSelfStruct = selfStructName(reaction.parent);

        // Count the output ports and inputs of contained reactors that
        // may be set by this reaction. This ignores actions in the effects.
        // Collect initialization statements for the output_produced array for the reaction
        // to point to the is_present field of the appropriate output.
        // These statements must be inserted after the array is malloc'd,
        // but we construct them while we are counting outputs.
        var outputCount = 0;
        val initialization = new StringBuilder()
        // The reaction.effects does not contain multiports, but rather the individual
        // ports of the multiport. We handle each multiport only once using this set.
        val handledMultiports = new LinkedHashSet<MultiportInstance>();
        for (effect : reaction.effects) {
            if (effect instanceof PortInstance) {
                // Effect is a port. There are six cases.
                // 1. The port is an ordinary port contained by the same reactor that contains this reaction.
                // 2. The port is a multiport contained by the same reactor that contains reaction.
                // 3. The port is an ordinary input port contained by a contained reactor.
                // 4. The port is a multiport input contained by a contained reactor.
                // 5. The port is an ordinary port contained by a contained bank of reactors.
                // 6. The port is an multiport contained by a contained bank of reactors.
                // Create the entry in the output_produced array for this port.
                // If the port is a multiport, then we need to create an entry for each
                // individual port.
                if (effect.multiport !== null && !handledMultiports.contains(effect.multiport)) {
                    // The effect is a port within a multiport that has not been handled yet.
                    handledMultiports.add(effect.multiport);
                    var allocate = false
                    if (!portAllocatedAlready.contains(effect.multiport)) {
                        // Prevent allocating memory more than once for the same port.
                        // It may have been allocated by a previous reaction that also
                        // has this port as an effect.
                        portAllocatedAlready.add(effect.multiport)
                        allocate = true
                    }
                    // Allocate memory where the data produced by the reaction will be stored
                    // and made available to the input of the contained reactor.
                    // This is done differently for ports like "c.in" than "out".
                    // This has to go at the end of the initialize_trigger_objects() function
                    // because the self struct of contained reactors has not yet been defined.
                    // FIXME: The following mallocs are not freed by the destructor!
                    if (effect.parent === reaction.parent) {
                        // The port belongs to the same reactor as the reaction.
                        val portStructType = variableStructType(
                            effect.definition,
                            reaction.parent.definition.reactorClass
                        )
                        if (allocate) {
                            pr(initializeTriggerObjectsEnd, '''
                                «nameOfSelfStruct»->__«effect.name»__width = «effect.multiport.width»;
                                // Allocate memory to store output of reaction.
                                «nameOfSelfStruct»->__«effect.name» = («portStructType»*)malloc(sizeof(«portStructType») 
                                    * «nameOfSelfStruct»->__«effect.name»__width); 
                            ''')
                        }
                        pr(initialization, '''
                            for (int i = 0; i < «effect.multiport.width»; i++) {
                                «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».output_produced[«outputCount» + i]
                                        = &«nameOfSelfStruct»->«getStackPortMember('''__«effect.name»[i]''', "is_present")»;
                            }
                        ''')
                    } else {
                        // The port belongs to a contained reactor.
                        val containerName = effect.parent.name
                        val portStructType = variableStructType(effect.definition,
                            effect.parent.definition.reactorClass)
                        if (allocate) {
                            pr(initializeTriggerObjectsEnd, '''
                                «nameOfSelfStruct»->__«containerName».«effect.name»__width = «effect.multiport.width»;
                                // Allocate memory for to store output of reaction feeding a multiport input of a contained reactor.
                                «nameOfSelfStruct»->__«containerName».«effect.name» = («portStructType»**)malloc(sizeof(«portStructType»*) 
                                    * «nameOfSelfStruct»->__«containerName».«effect.name»__width);
                                for (int i = 0; i < «nameOfSelfStruct»->__«containerName».«effect.name»__width; i++) {
                                    «nameOfSelfStruct»->__«containerName».«effect.name»[i] = («portStructType»*)malloc(sizeof(«portStructType»));
                                }
                            ''')
                        }
                        pr(initialization, '''
                            for (int i = 0; i < «nameOfSelfStruct»->__«containerName».«effect.name»__width; i++) {
                                «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».output_produced[«outputCount» + i]
                                        = &«nameOfSelfStruct»->__«containerName».«effect.name»[i]->is_present;
                            }
                        ''')
                    }
                    outputCount += effect.multiport.getWidth();
                } else if (effect.multiport === null && !(effect instanceof MultiportInstance)) {
                    // The effect is not a multiport nor a port contained by a multiport.
                    if (effect.parent === reaction.parent) {
                        // The port belongs to the same reactor as the reaction.
                        pr(initialization, '''
                            «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».output_produced[«outputCount»]
                                    = &«nameOfSelfStruct»->«getStackPortMember('''__«effect.name»''', "is_present")»;
                        ''')
                    } else {
                        // The port belongs to a contained reactor.
                        pr(initialization, '''
                            «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».output_produced[«outputCount»]
                                    = &«nameOfSelfStruct»->«getStackPortMember('''__«effect.parent.name».«effect.name»''', "is_present")»;
                        ''')
                    }
                    outputCount++
                }
            }
        }
        pr(initializeTriggerObjectsEnd, '''
            // Total number of outputs produced by the reaction.
            «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».num_outputs = «outputCount»;
            // Allocate arrays for triggering downstream reactions.
            if («nameOfSelfStruct»->___reaction_«reaction.reactionIndex».num_outputs > 0) {
                «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».output_produced 
                        = (bool**)malloc(sizeof(bool*) * «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».num_outputs);
                «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».triggers 
                        = (trigger_t***)malloc(sizeof(trigger_t**) * «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».num_outputs);
                «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».triggered_sizes 
                        = (int*)malloc(sizeof(int) * «nameOfSelfStruct»->___reaction_«reaction.reactionIndex».num_outputs);
            }
        ''')
        pr(initializeTriggerObjectsEnd, '''
            // Initialize the output_produced array.
            «initialization.toString»
        ''')
    } 
    
    /**
     * Generate code that is executed while the reactor instance is being initialized
     * @param initializationCode The StringBuilder appended to __initialize_trigger_objects()
     * @param instance The reactor instance
     * @param federate The federate instance
     */
    def void generateReactorInstanceExtension(StringBuilder initializationCode, ReactorInstance instance, FederateInstance federate) {
        // Do nothing
    }
    
    /**
     * Generate code that initializes the state variables for a given instance.
     * Unlike parameters, state variables are uniformly initialized for all instances
     * of the same reactor.
     * @param instance The reactor class instance
     * @return Initialization code fore state variables of instance
     */
    def generateStateVariableInitializations(ReactorInstance instance) {
        val reactorClass = instance.definition.reactorClass
        val nameOfSelfStruct = selfStructName(instance)
        for (stateVar : reactorClass.toDefinition.stateVars) {

            val initializer = getInitializer(stateVar, instance)
            if (stateVar.initialized) {
                if (stateVar.isOfTimeType) {
                    pr(initializeTriggerObjects, nameOfSelfStruct + "->" + stateVar.name + " = " + initializer + ";")
                } else {
                    // If the state is initialized with a parameter, then do not use
                    // a temporary variable. Otherwise, do, because
                    // static initializers for arrays and structs have to be handled
                    // this way, and there is no way to tell whether the type of the array
                    // is a struct.
                    if (stateVar.isParameterized && stateVar.init.size > 0) {
                        pr(initializeTriggerObjects,
                            nameOfSelfStruct + "->" + stateVar.name + " = " + initializer + ";")
                    } else {
                        var temporaryVariableName = instance.uniqueID + '_initial_' + stateVar.name
                        // To ensure uniqueness, if this reactor is in a bank, append the bank member index.
                        if (instance.bank !== null) {
                            temporaryVariableName += "_" + instance.bankIndex
                        }
                        // Array type has to be handled specially because C doesn't accept
                        // type[] as a type designator.
                        // Use the superclass to avoid [] being replaced by *.
                        var type = super.getTargetType(stateVar.inferredType)
                        val matcher = arrayPatternVariable.matcher(type)
                        if (matcher.find()) {
                            // If the state type ends in [], then we have to move the []
                            // because C is very picky about where this goes. It has to go
                            // after the variable name.
                            pr(
                                initializeTriggerObjects,
                                "static " + matcher.group(1) + " " + temporaryVariableName + "[] = " + initializer + ";"
                            )
                        } else {
                            pr(
                                initializeTriggerObjects,
                                "static " + type + " " + temporaryVariableName + " = " + initializer + ";"
                            )
                        }
                        pr(
                            initializeTriggerObjects,
                            nameOfSelfStruct + "->" + stateVar.name + " = " + temporaryVariableName + ";"
                        )
                    }
                }
            }
        }
    }
        
    /**
     * Generate runtime initialization code for parameters of a given reactor instance
     * @param builder The StringBuilder used to append the initialization code to
     * @param instance The reactor instance
     * @return initialization code
     */
    def generateParameterInitialization(StringBuilder builder, ReactorInstance instance) {
        var nameOfSelfStruct = selfStructName(instance)
        // Array type parameters have to be handled specially.
        // Use the superclass getTargetType to avoid replacing the [] with *.
        for (parameter : instance.parameters) {
            // NOTE: we now use the resolved literal value. For better efficiency, we could
            // store constants in a global array and refer to its elements to avoid duplicate
            // memory allocations.
            val targetType = super.getTargetType(parameter.type)
            val matcher = arrayPatternVariable.matcher(targetType)
            if (matcher.find()) {
                // Use an intermediate temporary variable so that parameter dependencies
                // are resolved correctly.
                val temporaryVariableName = parameter.uniqueID
                pr(builder, '''
                    static «matcher.group(1)» «temporaryVariableName»[] = «parameter.getInitializer»;
                    «nameOfSelfStruct»->«parameter.name» = «temporaryVariableName»;
                ''')
            } else {
                pr(builder, '''
                    «nameOfSelfStruct»->«parameter.name» = «parameter.getInitializer»; 
                ''')
            }

        }
    }
    
    /**
     * Generate code that malloc's memory for an output multiport.
     * @param builder The generated code is put into builder
     * @param output The output port to be initialized
     * @name
     */
    def initializeOutputMultiport(StringBuilder builder, Output output, String nameOfSelfStruct, ReactorInstance instance) {
        val reactor = instance.definition.reactorClass
        pr(builder, '''
            «nameOfSelfStruct»->__«output.name»__width = «multiportWidthSpecInC(output, null, instance)»;
            // Allocate memory for multiport output.
            «nameOfSelfStruct»->__«output.name» = («variableStructType(output, reactor)»*)malloc(sizeof(«variableStructType(output, reactor)») * «nameOfSelfStruct»->__«output.name»__width); 
        ''')
    }
    
    /**
     * If the argument is a multiport, return a string that is a valid
     * C expression consisting of an (optional) integer added to any number of
     * parameter references on the specified self struct.
     * @param port The port.
     * @param contained If the port belongs to a contained reactor, then
     *  the contained reactor's instantiation. Otherwise, null.
     * @param reactorInstance The reactor referring to this port.
     * @return The width expression for a multiport or an empty string if it is
     *  not a multiport.
     */
    protected def String multiportWidthSpecInC(Port port, Instantiation contained, ReactorInstance reactorInstance) {
        var result = new StringBuilder()
        var count = 0
        // Caution: If port belongs to a contained reactor, the self struct needs to be that
        // of the contained reactor instance, not this container.
        var selfStruct = selfStructName(reactorInstance)
        if (contained !== null) {
            selfStruct = selfStructName(reactorInstance.getChildReactorInstance(contained))
        }
        if (port.widthSpec !== null) {
            if (!port.widthSpec.ofVariableLength) {
                for (term : port.widthSpec.terms) {
                    if (term.parameter !== null) {
                        result.append(selfStruct)
                        result.append('->')
                        result.append(getTargetReference(term.parameter))
                    } else {
                        count += term.width
                    }
                }
            }
        }
        if (count > 0) {
            if (result.length > 0) {
                result.append(' + ')
            }
            result.append(count)
        }
        return result.toString
    }
    
    protected def getInitializer(StateVar state, ReactorInstance parent) {
        var list = new LinkedList<String>();

        for (i : state?.init) {
            if (i.parameter !== null) {
                list.add(parent.selfStructName + "->" + i.parameter.name)
            } else if (state.isOfTimeType) {
                list.add(i.targetTime)
            } else {
                list.add(i.targetValue)
            }
        }
        
        if (list.size == 1)
            return list.get(0)
        else
            return list.join('{', ', ', '}', [it])
    }
    
    /** 
     * Return true if the specified reactor instance belongs to the specified
     * federate. This always returns true if the specified federate is
     * null or a singleton. Otherwise, it returns true only if the
     * instance is contained within the specified federate. 
     * 
     * @param instance A reactor instance.
     * @param federate A federate or null if there are no federates.
     */
    def reactorBelongsToFederate(ReactorInstance instance, FederateInstance federate) {
        return (federate === null || federate.contains(instance));
    }

    /** Set the reaction priorities based on dependency analysis.
     *  @param reactor The reactor on which to do this.
     *  @param federate A federate to conditionally generate code for
     *   contained reactors or null if there are no federates.
     */
    def void setReactionPriorities(ReactorInstance reactor, FederateInstance federate) {
        // Use "reactionToReactionTName" property of reactionInstance
        // to set the levels.
        var reactionCount = 0
        for (reactionInstance : reactor.reactions) {
            if (federate === null || federate.containsReaction(
                reactor.definition.reactorClass.toDefinition,
                reactionInstance.definition
            )) {
                val reactionStructName = '''«selfStructName(reactionInstance.parent)»->___reaction_«reactionCount»'''
                val reactionIndex = "0x" + (reactionInstance.deadline.toNanoSeconds.shiftLeft(16)).or(
                    new BigInteger(reactionInstance.level.toString)).toString(16) + "LL"
                pr('''
                    «reactionStructName».chain_id = «reactionInstance.chainID.toString»;
                    // index is the OR of level «reactionInstance.level» and 
                    // deadline «reactionInstance.deadline.toNanoSeconds» shifted left 16 bits.
                    «reactionStructName».index = «reactionIndex»;
                ''')
            }
            // Increment reaction count even if it is not in the federate for consistency.
            reactionCount++;
        }
        for (child : reactor.children) {
            if (reactorBelongsToFederate(child, federate)) {
                setReactionPriorities(child, federate)
            }
        }
    }

    // //////////////////////////////////////////
    // // Protected methods.

    /**
     * Generate code for the body of a reaction that takes an input and
     * schedules an action with the value of that input.
     * @param action The action to schedule
     * @param port The port to read from
     */
    override generateDelayBody(Action action, VarRef port) { 
        val ref = generateVarRef(port);
        // Note that the action.type set by the base class is actually
        // the port type.
        if (action.inferredType.isTokenType) {
            '''
            if («ref»->is_present) {
                // Put the whole token on the event queue, not just the payload.
                // This way, the length and element_size are transported.
                schedule_token(«action.name», 0, «ref»->token);
            }
            '''
        } else {
            '''
            schedule_copy(«action.name», 0, &«ref»->value, 1);  // Length is 1.
            '''
        }
    }
    
    /**
     * Generate code for the body of a reaction that is triggered by the
     * given action and writes its value to the given port. This realizes
     * the receiving end of a logical delay specified with the 'after'
     * keyword.
     * @param action The action that triggers the reaction
     * @param port The port to write to.
     */
    override generateForwardBody(Action action, VarRef port) {
        val outputName = generateVarRef(port)
        if (action.inferredType.isTokenType) {
            // Forward the entire token and prevent freeing.
            // Increment the ref_count because it will be decremented
            // by both the action handling code and the input handling code.
            '''
            «DISABLE_REACTION_INITIALIZATION_MARKER»
            self->__«outputName».value = («action.inferredType.targetType»)self->___«action.name».token->value;
            self->__«outputName».token = (lf_token_t*)self->___«action.name».token;
            ((lf_token_t*)self->___«action.name».token)->ref_count++;
            self->«getStackPortMember('''__«outputName»''', "is_present")» = true;
            '''
        } else {
            '''
            SET(«outputName», «action.name»->value);
            '''
        }
    }

    /**
     * Generate code for the body of a reaction that handles the
     * action that is triggered by receiving a message from a remote
     * federate.
     * @param action The action.
     * @param sendingPort The output port providing the data to send.
     * @param receivingPort The ID of the destination port.
     * @param receivingPortID The ID of the destination port.
     * @param sendingFed The sending federate.
     * @param receivingFed The destination federate.
     * @param receivingBankIndex The receiving federate's bank index, if it is in a bank.
     * @param receivingChannelIndex The receiving federate's channel index, if it is a multiport.
     * @param type The type.
     * @param isPhysical Indicates whether or not the connection is physical
     */
    override generateNetworkReceiverBody(
        Action action,
        VarRef sendingPort,
        VarRef receivingPort,
        int receivingPortID, 
        FederateInstance sendingFed,
        FederateInstance receivingFed,
        int receivingBankIndex,
        int receivingChannelIndex,
        InferredType type,
        boolean isPhysical
    ) {
        // Adjust the type of the action and the receivingPort.
        // If it is "string", then change it to "char*".
        // This string is dynamically allocated, and type 'string' is to be
        // used only for statically allocated strings.
        if (action.type.targetType == "string") {
            action.type.code = null
            action.type.id = "char*"
        }
        if ((receivingPort.variable as Port).type.targetType == "string") {
            (receivingPort.variable as Port).type.code = null
            (receivingPort.variable as Port).type.id = "char*"
        }

        var receiveRef = generatePortRef(receivingPort, receivingBankIndex, receivingChannelIndex)
        val result = new StringBuilder()
      
        // Transfer the physical time of arrival from the action to the port
        result.append('''
            «receiveRef»->physical_time_of_arrival = self->___«action.name».physical_time_of_arrival;
        ''')
        
        if (isTokenType(type)) {
            result.append('''
                SET_TOKEN(«receiveRef», «action.name»->token);
            ''')
        } else {
            // NOTE: Docs say that malloc'd char* is freed on conclusion of the time step.
            // So passing it downstream should be OK.
            result.append('''
                SET(«receiveRef», «action.name»->value);
            ''')
        }
        
        return result.toString
    }

    /**
     * Generate code for the body of a reaction that handles an output
     * that is to be sent over the network.
     * @param sendingPort The output port providing the data to send.
     * @param receivingPort The variable reference to the destination port.
     * @param receivingPortID The ID of the destination port.
     * @param sendingFed The sending federate.
     * @param sendingBankIndex The bank index of the sending federate, if it is a bank.
     * @param sendingChannelIndex The channel index of the sending port, if it is a multiport.
     * @param receivingFed The destination federate.
     * @param type The type.
     * @param isPhysical Indicates whether the connection is physical or not
     * @param delay The delay value imposed on the connection using after
     */
    override generateNetworkSenderBody(
        VarRef sendingPort,
        VarRef receivingPort,
        int receivingPortID, 
        FederateInstance sendingFed,
        int sendingBankIndex,
        int sendingChannelIndex,
        FederateInstance receivingFed,
        InferredType type,
        boolean isPhysical,
        Delay delay
    ) { 
        var sendRef = generatePortRef(sendingPort, sendingBankIndex, sendingChannelIndex);
        val receiveRef = generateVarRef(receivingPort); // Used for comments only, so no need for bank/multiport index.
        val result = new StringBuilder()
        result.append('''
            // Sending from «sendRef» in federate «sendingFed.name» to «receiveRef» in federate «receivingFed.name»
        ''')
        // If the connection is physical and the receiving federate is remote, send it directly on a socket.
        // If the connection is logical and the coordination mode is centralized, send via RTI.
        // If the connection is logical and the coordination mode is decentralized, send directly
        var String messageType;
        // Name of the next immediate destination of this message
        var String next_destination_name = '''"federate «receivingFed.id»"'''
        
        // Get the delay literal
        var String additionalDelayString = 
            CGeneratorExtension.getNetworkDelayLiteral(
                delay, 
                this
            );
        
        if (isPhysical) {
            messageType = "MSG_TYPE_P2P_MESSAGE"
        } else if (targetConfig.coordination === CoordinationType.DECENTRALIZED) {
            messageType = "MSG_TYPE_P2P_TAGGED_MESSAGE"
        } else {
            // Logical connection
            // Send the message via rti
            messageType = "MSG_TYPE_TAGGED_MESSAGE"
            next_destination_name = '''"federate «receivingFed.id» via the RTI"'''
        }
        
        
        var String sendingFunction = '''send_timed_message'''
        var String commonArgs = '''«additionalDelayString», 
                   «messageType»,
                   «receivingPortID»,
                   «receivingFed.id»,
                   «next_destination_name»,
                   message_length'''
        if (isPhysical) {
            // Messages going on a physical connection do not
            // carry a timestamp or require the delay;
            sendingFunction = '''send_message'''            
            commonArgs = '''«messageType», «receivingPortID», «receivingFed.id»,
                   «next_destination_name», message_length'''
        }
        
        if (isTokenType(type)) {
            // NOTE: Transporting token types this way is likely to only work if the sender and receiver
            // both have the same endianess. Otherwise, you have to use protobufs or some other serialization scheme.
            result.append('''
                size_t message_length = «sendRef»->token->length * «sendRef»->token->element_size;
                «sendingFunction»(«commonArgs», (unsigned char*) «sendRef»->value);
            ''')
        } else {
            // Handle native types.
            // string types need to be dealt with specially because they are hidden pointers.
            // void type is odd, but it avoids generating non-standard expression sizeof(void),
            // which some compilers reject.
            var lengthExpression = switch(type.targetType) {
                case 'string': '''strlen(«sendRef»->value) + 1'''
                case 'void': '0'
                default: '''sizeof(«type.targetType»)'''
            }
            var pointerExpression = switch(type.targetType) {
                case 'string': '''(unsigned char*) «sendRef»->value'''
                default: '''(unsigned char*)&«sendRef»->value'''
            }
            result.append('''
            size_t message_length = «lengthExpression»;
            «sendingFunction»(«commonArgs», «pointerExpression»);
            ''')
        }
        return result.toString
    }
    
    /**
     * Generate code for the body of a reaction that decides whether the trigger for the given
     * port is going to be present or absent for the current logical time.
     * This reaction is put just before the first reaction that is triggered by the network
     * input port "port" or has it in its sources. If there are only connections to contained 
     * reactors, in the top-level reactor.
     * 
     * @param port The port to generate the control reaction for
     * @param maxSTP The maximum value of STP is assigned to reactions (if any)
     *  that have port as their trigger or source
     */
    override generateNetworkInputControlReactionBody(
        int receivingPortID,
        TimeValue maxSTP
    ) {
        // Store the code
        val result = new StringBuilder()
        
        result.append('''
                interval_t max_STP = 0LL;
        ''');
        
        // Find the maximum STP for decentralized coordination
        if(isFederatedAndDecentralized) {
            result.append('''
                max_STP = «maxSTP.timeInTargetLanguage»;
            ''')  
        }
        
        result.append('''
            // Wait until the port status is known
            wait_until_port_status_known(«receivingPortID», max_STP);
        ''')
        
        return result.toString        
    }

    /**
     * Generate code for the body of a reaction that sends a port status message for the given
     * port if it is absent.
     * 
     * @param port The port to generate the control reaction for
     * @param portID The ID assigned to the port in the AST transformation
     * @param receivingFederateID The ID of the receiving federate
     * @param sendingBankIndex The bank index of the sending federate, if it is a bank.
     * @param sendingChannelIndex The channel if a multiport
     * @param delay The delay value imposed on the connection using after
     */
    override generateNetworkOutputControlReactionBody(
        VarRef port,
        int portID,
        int receivingFederateID,
        int sendingBankIndex,
        int sendingChannelIndex,
        Delay delay
    ) {
        // Store the code
        val result = new StringBuilder();
        var sendRef = generatePortRef(port, sendingBankIndex, sendingChannelIndex);
        
        // Get the delay literal
        var String additionalDelayString = 
            CGeneratorExtension.getNetworkDelayLiteral(
                delay, 
                this
            );
        
        result.append('''
            // If the output port has not been SET for the current logical time,
            // send an ABSENT message to the receiving federate            
            LOG_PRINT("Contemplating whether to send port "
                       "absent for port %d to federate %d.", 
                       «portID», «receivingFederateID»);
            if (!«sendRef»->is_present) {
                send_port_absent_to_federate(«additionalDelayString», «portID», «receivingFederateID»);
            }
        ''')
        
        
        return result.toString();
               
    }  

    /** Generate #include of pqueue.c and either reactor.c or reactor_threaded.c
     *  depending on whether threads are specified in target directive.
     *  As a side effect, this populates the runCommand and compileCommand
     *  private variables if such commands are specified in the target directive.
     */
    override generatePreamble() {
        pr(this.defineLogLevel)
        
        if (isFederated) {
            // FIXME: Instead of checking
            // #ifdef FEDERATED, we could
            // use #if (NUMBER_OF_FEDERATES > 1)
            // To me, the former is more accurate.
            pr('''
                #define FEDERATED
            ''')
            if (targetConfig.coordination === CoordinationType.CENTRALIZED) {
                // The coordination is centralized.
                pr('''
                    #define FEDERATED_CENTRALIZED
                ''')                
            } else if (targetConfig.coordination === CoordinationType.DECENTRALIZED) {
                // The coordination is decentralized
                pr('''
                    #define FEDERATED_DECENTRALIZED
                ''')
            }
        }
        
        includeTargetLanguageHeaders()

        pr('#define NUMBER_OF_FEDERATES ' + federates.size);
        
        pr('#define TARGET_FILES_DIRECTORY "' + fileConfig.srcGenPath + '"');
        
        if (targetConfig.coordinationOptions.advance_message_interval !== null) {
            pr('#define ADVANCE_MESSAGE_INTERVAL ' + targetConfig.coordinationOptions.advance_message_interval.timeInTargetLanguage)
        }
                        
        // Handle target parameters.
        // First, if there are federates, then ensure that threading is enabled.
        if (isFederated) {
            for (federate : federates) {
                // The number of threads needs to be at least one larger than the input ports
                // to allow the federate to wait on all input ports while allowing an additional
                // worker thread to process incoming messages.
                if (targetConfig.threads < federate.networkMessageActions.size + 1) {
                    targetConfig.threads = federate.networkMessageActions.size + 1;
                }            
            }
        }
        
        includeTargetLanguageSourceFiles()
        
        // Do this after the above includes so that the preamble can
        // call built-in functions.
        super.generatePreamble()

        parseTargetParameters()
        
        // Make sure src-gen directory exists.
        fileConfig.getSrcGenPath.toFile.mkdirs
        
        // Handle .proto files.
        for (file : targetConfig.protoFiles) {
            this.processProtoFile(file)
            val dotIndex = file.lastIndexOf('.')
            var rootFilename = file
            if (dotIndex > 0) {
                rootFilename = file.substring(0, dotIndex)
            }
            pr('#include "' + rootFilename + '.pb-c.h"')
        }
    }
    
    /**
     * Parse the target parameters and set flags to the runCommand
     * accordingly.
     */
    def parseTargetParameters() {
        if (targetConfig.fastMode) {
            // The runCommand has a first entry that is ignored but needed.
            if (runCommand.length === 0) {
                runCommand.add(topLevelName)
            }
            runCommand.add("-f")
            runCommand.add("true")
        }
        if (targetConfig.keepalive) {
            // The runCommand has a first entry that is ignored but needed.
            if (runCommand.length === 0) {
                runCommand.add(topLevelName)
            }
            runCommand.add("-k")
            runCommand.add("true")
        }
        if (targetConfig.timeout !== null) {
            // The runCommand has a first entry that is ignored but needed.
            if (runCommand.length === 0) {
                runCommand.add(topLevelName)
            }
            runCommand.add("-o")
            runCommand.add(targetConfig.timeout.time.toString)
            runCommand.add(targetConfig.timeout.unit.toString)
        }
        
    }
    
    /** Add necessary header files specific to the target language.
     *  Note. The core files always need to be (and will be) copied 
     *  uniformly across all target languages.
     */
    protected def includeTargetLanguageHeaders() {
        if (targetConfig.tracing !== null) {
            var filename = "";
            if (targetConfig.tracing.traceFileName !== null) {
                filename = targetConfig.tracing.traceFileName;
            }
            pr('#define LINGUA_FRANCA_TRACE ' + filename)
        }
        
        pr('#include "ctarget.h"')
        if (targetConfig.tracing !== null) {
            pr('#include "core/trace.c"')            
        }
    }
    
    /** Add necessary source files specific to the target language.  */
    protected def includeTargetLanguageSourceFiles() {
        if (targetConfig.threads > 0) {
            // Set this as the default in the generated code,
            // but only if it has not been overridden on the command line.
            pr(startTimers, '''
                if (_lf_number_of_threads == 0) {
                   _lf_number_of_threads = «targetConfig.threads»;
                }
            ''')
            pr("#include \"core/reactor_threaded.c\"")
        } else {
            pr("#include \"core/reactor.c\"")
        }
        if (isFederated) {
            pr("#include \"core/federate.c\"")
        }
    }

    // Regular expression pattern for compiler error messages with resource
    // and line number information. The first match will a resource URI in the
    // form of "file:/path/file.lf". The second match will be a line number.
    // The third match is a character position within the line.
    // The fourth match will be the error message.
    static final Pattern compileErrorPattern = Pattern.compile("^(file:/.*):([0-9]+):([0-9]+):(.*)$");
    
    /** Given a line of text from the output of a compiler, return
     *  an instance of ErrorFileAndLine if the line is recognized as
     *  the first line of an error message. Otherwise, return null.
     *  @param line A line of output from a compiler or other external
     *   tool that might generate errors.
     *  @return If the line is recognized as the start of an error message,
     *   then return a class containing the path to the file on which the
     *   error occurred (or null if there is none), the line number (or the
     *   string "1" if there is none), the character position (or the string
     *   "0" if there is none), and the message (or an empty string if there
     *   is none).
     */
    override parseCommandOutput(String line) {
        val matcher = compileErrorPattern.matcher(line)
        if (matcher.find()) {
            val result = new ErrorFileAndLine()
            result.filepath = matcher.group(1)
            result.line = matcher.group(2)
            result.character = matcher.group(3)
            result.message = matcher.group(4)
            
            if (result.message.toLowerCase.contains("warning:")) {
                result.isError = false
            }
            return result
        }
        return null as ErrorFileAndLine
    }
    
    
    /**
     * Strip all line directives from the given C code.
     * @param code The code to remove # line directives from.
     * @return The code without #line directives.
     */
     def removeLineDirectives(String code) {
        
        val separator = System.getProperty("line.separator")
        val lines = code.split(separator)
        
        val builder = new StringBuilder("")
        
        for(line : lines) {
            val trimmedLine = line.trim()
            if(!trimmedLine.startsWith("#line")) {
                builder.append(line).append(separator)
            }
        }
        return builder.toString()
     }
        
    // //////////////////////////////////////////
    // // Private methods.
    
    /** Perform deferred initializations in initialize_trigger_objects.
     *  @param federate The federate for which we are doing this.
     */
    private def doDeferredInitialize(FederateInstance federate) {
        // First, populate the trigger tables for each output.
        // The entries point to the trigger_t structs for the destination inputs.
        pr('// doDeferredInitialize')

        // For outputs that are not primitive types (of form type* or type[]),
        // create a default token on the self struct.
        createDefaultTokens(main, federate)

        // Next, for every input port, populate its "self" struct
        // fields with pointers to the output port that sends it data.
        connectInputsToOutputs(main, federate)
    }

    /** Generate assignments of pointers in the "self" struct of a destination
     *  port's reactor to the appropriate entries in the "self" struct of the
     *  source reactor.
     *  @param instance The reactor instance.
     *  @param federate The federate for which we are generating code or null
     *   if there is no federation.
     */
    private def void connectInputsToOutputs(ReactorInstance instance, FederateInstance federate) {
        if (!reactorBelongsToFederate(instance, federate)) {
            return;
        }
        pr('''// Connect inputs and outputs for reactor «instance.getFullName».''')
        // For destinations that are multiports, need to count channels
        // in case there is more than one connection.
        var destinationChannelCount = new LinkedHashMap<PortInstance,Integer>()
        for (source : instance.destinations.keySet) {
            // If the source is an input port, find the ultimate source,
            // which could be the input port if it is written to by a reaction
            // or it could be an upstream output port. 
            var eventualSource = sourcePort(source)
            
            // We assume here that all connections across federates have been
            // broken and replaced by reactions handling the communication.
            // Moreover, if the eventual source is an input and it is NOT
            // written to by a reaction, then it is dangling, so we skip it.
            if (reactorBelongsToFederate(eventualSource.parent, federate)
                && (eventualSource.isOutput
                || eventualSource.dependsOnReactions.size > 0)
            ) {
                val destinations = instance.destinations.get(source)
                // For multiports, need to count the channels in case there are multiple
                // destinations.
                var sourceChannelCount = 0
                for (destination : destinations) {
                    // Check to see if the destination reactor belongs to the federate.
                    if (reactorBelongsToFederate(destination.parent, federate)) {
                        // If the destination is an output, then skip this step.
                        // Outputs are handled by finding the transitive closure
                        // (finding the eventual inputs).
                        if (destination.isInput) {
                            var comment = ''
                            if (source !== eventualSource) {
                                comment = ''' (eventual source is «eventualSource.getFullName»)'''
                            }
                            val destStructType = variableStructType(
                                destination.definition as TypedVariable,
                                destination.parent.definition.reactorClass
                            )
                            // There are four cases, depending on whether the source or
                            // destination or both are multiports.
                            if (eventualSource instanceof MultiportInstance) {
                                // Source is a multiport. 
                                // Number of available channels:
                                var width = eventualSource.instances.size - sourceChannelCount
                                // If there are no more available channels, there is nothing to do.
                                if (width > 0) {
                                    if (destination instanceof MultiportInstance) {
                                        // Source and destination are both multiports.
                                        // First, get the first available destination channel.
                                        var destinationChannel = destinationChannelCount.get(destination)
                                        if (destinationChannel === null) {
                                            destinationChannel = 0
                                            destinationChannelCount.put(destination, 1)
                                        } else {
                                            // Add the width of the source to the index of the destination's
                                            // next available channel. This may be out of bounds for the
                                            // destination.
                                            destinationChannelCount.put(destination, destinationChannel + width)
                                        }
                                        // There will be nothing to do if the destination channel index
                                        // is out of bounds.
                                        if (destinationChannel < destination.instances.size) {
                                            // There is at least one available channel at the destination.
                                            // The number of connections now will be the minimum of the
                                            // source width and the number of remaining channels at the
                                            // destination.
                                            if (destination.instances.size - destinationChannel < width) {
                                                width = destination.instances.size - destinationChannel
                                            }
                                            // Finally, we can generate the code to make the connections.
                                            pr('''
                                                // Connect «source.getFullName»«comment» to input port «destination.getFullName»
                                                int j = «sourceChannelCount»;
                                                for (int i = «destinationChannel»; i < «destinationChannel» + «width»; i++) {
                                                    «destinationReference(destination)»[i]
                                                        = («destStructType»*)«sourceReference(eventualSource)»[j++];
                                                }
                                            ''')
                                            sourceChannelCount += width
                                        } else {
                                            pr('''
                                                // No destination channels available for connection from
                                                // «source.getFullName»«comment» to input port «destination.getFullName».
                                            ''')
                                        }
                                    } else {
                                        // Source is a multiport, destination is a single port.
                                        pr('''
                                            // Connect «source.getFullName»«comment» to input port «destination.getFullName»
                                            «destinationReference(destination)»
                                                    = («destStructType»*)«sourceReference(eventualSource)»[«sourceChannelCount»];
                                        ''')
                                        sourceChannelCount++
                                    }
                                } else {
                                    pr('''
                                        // No source channels available for connection from
                                        // «source.getFullName»«comment» to input port «destination.getFullName».
                                    ''')
                                }
                            } else if (destination instanceof MultiportInstance) {
                                // Source is a single port, Destination is a multiport.
                                // First, get the first available destination channel.
                                var destinationChannel = destinationChannelCount.get(destination)
                                if (destinationChannel === null) {
                                    destinationChannel = 0
                                    destinationChannelCount.put(destination, 1)
                                } else {
                                    // Add the width of the source to the index of the destination's
                                    // next available channel. This may be out of bounds for the
                                    // destination.
                                    destinationChannelCount.put(destination, destinationChannel + 1)
                                }
                                // There will be nothing to do if the destination channel index
                                // is out of bounds.
                                if (destinationChannel < destination.instances.size) {
                                    pr('''
                                        // Connect «source.getFullName»«comment» to input port «destination.getFullName»
                                        «destinationReference(destination)»[«destinationChannel»]
                                                = («destStructType»*)«sourceReference(eventualSource)»;
                                    ''')
                                } else {
                                    pr('''
                                        // No destination channels available for connection from
                                        // «source.getFullName»«comment» to input port «destination.getFullName».
                                    ''')
                                }
                            } else {
                                // Both ports are single ports.
                                pr('''
                                    // Connect «source.getFullName»«comment» to input port «destination.getFullName»
                                    «destinationReference(destination)» = («destStructType»*)«sourceReference(eventualSource)»;
                                ''')
                            }
                        }
                    }
                }
            }
        }

        for (child : instance.children) {
            // In case this is a composite, recurse.
            connectInputsToOutputs(child, federate)
        }

        // Handle inputs that get sent data from a reaction rather than from
        // another contained reactor and reactions that are triggered by an
        // output of a contained reactor.
        for (reaction : instance.reactions) {
            for (port : reaction.effects.filter(PortInstance)) {
                if (port.definition instanceof Input && !(port instanceof MultiportInstance)) {
                    // This reaction is sending to an input. Must be
                    // the input of a contained reactor.
                    // It may be deeply contained, however, in which case
                    // we have to trace back to where the data and is_present
                    // variables are.
                    // Skip multiport instances and connect the contained individual ports instead.
                    var sourcePort = sourcePort(port)
                    if (reactorBelongsToFederate(sourcePort.parent, federate)) {
                        val destStructType = variableStructType(
                            port.definition as TypedVariable,
                            port.parent.definition.reactorClass
                        )
                        pr('''
                            // Connect «sourcePort», which gets data from reaction «reaction.reactionIndex»
                            // of «instance.getFullName», to «port.getFullName».
                            «destinationReference(port)» = («destStructType»*)«sourceReference(sourcePort)»;
                        ''')
                    }
                }
            }
            for (port : reaction.sources.filter(PortInstance)) {
                if (port.definition instanceof Output) {
                    // This reaction is receiving data from an output
                    // of a contained reactor. If the contained reactor is
                    // not in the federate, then we don't do anything here.
                    if (reactorBelongsToFederate(port.parent, federate)) {
                        val destStructType = variableStructType(
                            port.definition as TypedVariable,
                            port.parent.definition.reactorClass
                        )
                        if (!(port instanceof MultiportInstance)) {
                            pr('''
                                // Record output «port.getFullName», which triggers reaction «reaction.reactionIndex»
                                // of «instance.getFullName», on its self struct.
                                «reactionReference(port)» = («destStructType»*)«sourceReference(port)»;
                            ''')
                        } else {
                            pr('''
                                for (int i = 0; i < «reactionReference(port)»__width; i++) {
                                    «reactionReference(port)»[i] = («destStructType»*)«sourceReference(port)»[i];
                                }
                            ''')
                        }
                    }
                }
            }
        }
        pr('''// END Connect inputs and outputs for reactor «instance.getFullName».''')
    }
    
    /**
     * Given an input port instance, if it receives its data from a reaction somewhere up
     * in the hierarchy, return the port to which the reaction actually writes.
     * The returned port will be this same port if the parent's parent's reaction
     * writes directly to this port, but if this port is deeper in the hierarchy,
     * then this will be a port belonging to highest parent of this port where
     * the parent is contained by the same reactor whose reaction writes to this
     * port.  This method is useful to find the name of the items on the self
     * struct of the reaction's parent that contain the value being sent
     * and its is_present variable.
     * @param port The input port instance.
     */
    private static def PortInstance sourcePort(PortInstance port) {
        // If the port depends on reactions, then this is the port we are looking for.
        if (port.dependsOnReactions.size > 0) return port
        if (port.dependsOnPort === null) return port
        // If we get here, then this port is fed data from another port.
        // Find the source for that port.
        return sourcePort(port.dependsOnPort)
    }

    /** Generate action variables for a reaction.
     *  @param builder The string builder into which to write the code.
     *  @param action The action.
     *  @param reactor The reactor.
     */
    private def generateActionVariablesInReaction(
        StringBuilder builder,
        Action action,
        ReactorDecl decl
    ) {
        val structType = variableStructType(action, decl)
        // If the action has a type, create variables for accessing the value.
        val type = action.inferredType
        // Pointer to the lf_token_t sent as the payload in the trigger.
        val tokenPointer = '''(self->___«action.name».token)'''
        pr(action, builder, '''
            // Expose the action struct as a local variable whose name matches the action name.
            «structType»* «action.name» = &self->__«action.name»;
            // Set the fields of the action struct to match the current trigger.
            «action.name»->is_present = (bool)self->___«action.name».status;
            «action.name»->has_value = («tokenPointer» != NULL && «tokenPointer»->value != NULL);
            «action.name»->token = «tokenPointer»;
        ''')
        // Set the value field only if there is a type.
        if (!type.isUndefined) {
            // The value field will either be a copy (for primitive types)
            // or a pointer (for types ending in *).
            pr(action, builder, '''
                if («action.name»->has_value) {
                    «IF type.isTokenType»
                        «action.name»->value = («type.targetType»)«tokenPointer»->value;
                    «ELSE»
                        «action.name»->value = *(«type.targetType»*)«tokenPointer»->value;
                    «ENDIF»
                }
            ''')
        }
    }
    
    /** Generate into the specified string builder the code to
     *  initialize local variables for the specified input port
     *  in a reaction function from the "self" struct.
     *  @param builder The string builder.
     *  @param input The input statement from the AST.
     *  @param reactor The reactor.
     */
    private def generateInputVariablesInReaction(
        StringBuilder builder,
        Input input,
        ReactorDecl decl
    ) {
        val structType = variableStructType(input, decl)
        val inputType = input.inferredType
        
        // Create the local variable whose name matches the input name.
        // If the input has not been declared mutable, then this is a pointer
        // to the upstream output. Otherwise, it is a copy of the upstream output,
        // which nevertheless points to the same token and value (hence, as done
        // below, we have to use writable_copy()). There are 8 cases,
        // depending on whether the input is mutable, whether it is a multiport,
        // and whether it is a token type.
        // Easy case first.
        if (!input.isMutable && !inputType.isTokenType && !input.isMultiport) {
            // Non-mutable, non-multiport, primitive type.
            pr(builder, '''
                «structType»* «input.name» = self->__«input.name»;
            ''')
        } else if (input.isMutable && !inputType.isTokenType && !input.isMultiport) {
            // Mutable, non-multiport, primitive type.
            pr(builder, '''
                // Mutable input, so copy the input into a temporary variable.
                // The input value on the struct is a copy.
                «structType» __tmp_«input.name» = *(self->__«input.name»);
                «structType»* «input.name» = &__tmp_«input.name»;
            ''')
        } else if (!input.isMutable && inputType.isTokenType && !input.isMultiport) {
            // Non-mutable, non-multiport, token type.
            pr(builder, '''
                «structType»* «input.name» = self->__«input.name»;
                if («input.name»->is_present) {
                    «input.name»->length = «input.name»->token->length;
                    «input.name»->value = («inputType.targetType»)«input.name»->token->value;
                } else {
                    «input.name»->length = 0;
                }
            ''')
        } else if (input.isMutable && inputType.isTokenType && !input.isMultiport) {
            // Mutable, non-multiport, token type.
            pr(builder, '''
                // Mutable input, so copy the input struct into a temporary variable.
                «structType» __tmp_«input.name» = *(self->__«input.name»);
                «structType»* «input.name» = &__tmp_«input.name»;
                if («input.name»->is_present) {
                    «input.name»->length = «input.name»->token->length;
                    lf_token_t* _lf_input_token = «input.name»->token;
                    «input.name»->token = writable_copy(_lf_input_token);
                    if («input.name»->token != _lf_input_token) {
                        // A copy of the input token has been made.
                        // This needs to be reference counted.
                        «input.name»->token->ref_count = 1;
                        // Repurpose the next_free pointer on the token to add to the list.
                        «input.name»->token->next_free = _lf_more_tokens_with_ref_count;
                        _lf_more_tokens_with_ref_count = «input.name»->token;
                    }
                    «input.name»->value = («inputType.targetType»)«input.name»->token->value;
                } else {
                    «input.name»->length = 0;
                }
            ''')            
        } else if (!input.isMutable && input.isMultiport) {
            // Non-mutable, multiport, primitive or token type.
            pr(builder, '''
                «structType»** «input.name» = self->__«input.name»;
            ''')
        } else if (inputType.isTokenType) {
            // Mutable, multiport, token type
            pr(builder, '''
                // Mutable multiport input, so copy the input structs
                // into an array of temporary variables on the stack.
                «structType» __tmp_«input.name»[«input.multiportWidthExpression»];
                «structType»* «input.name»[«input.multiportWidthExpression»];
                for (int i = 0; i < «input.multiportWidthExpression»; i++) {
                    «input.name»[i] = &__tmp_«input.name»[i];
                    __tmp_«input.name»[i] = *(self->__«input.name»[i]);
                    // If necessary, copy the tokens.
                    if («input.name»[i]->is_present) {
                        «input.name»[i]->length = «input.name»[i]->token->length;
                        lf_token_t* _lf_input_token = «input.name»[i]->token;
                        «input.name»[i]->token = writable_copy(_lf_input_token);
                        if («input.name»[i]->token != _lf_input_token) {
                            // A copy of the input token has been made.
                            // This needs to be reference counted.
                            «input.name»[i]->token->ref_count = 1;
                            // Repurpose the next_free pointer on the token to add to the list.
                            «input.name»[i]->token->next_free = _lf_more_tokens_with_ref_count;
                            _lf_more_tokens_with_ref_count = «input.name»[i]->token;
                        }
                        «input.name»[i]->value = («inputType.targetType»)«input.name»[i]->token->value;
                    } else {
                        «input.name»[i]->length = 0;
                    }
                }
            ''')
        } else {
            // Mutable, multiport, primitive type
            pr(builder, '''
                // Mutable multiport input, so copy the input structs
                // into an array of temporary variables on the stack.
                «structType» __tmp_«input.name»[«input.multiportWidthExpression»];
                «structType»* «input.name»[«input.multiportWidthExpression»];
                for (int i = 0; i < «input.multiportWidthExpression»; i++) {
                    «input.name»[i]  = &__tmp_«input.name»[i];
                    // Copy the struct, which includes the value.
                    __tmp_«input.name»[i] = *(self->__«input.name»[i]);
                }
            ''')
        }
        // Set the _width variable for all cases. This will be -1
        // for a variable-width multiport, which is not currently supported.
        // It will be -2 if it is not multiport.
        pr(builder, '''
            int «input.name»_width = self->__«input.name»__width;
        ''')
    }
    
    /** Generate into the specified string builder the code to
     *  initialize local variables for ports in a reaction function
     *  from the "self" struct. The port may be an input of the
     *  reactor or an output of a contained reactor. The second
     *  argument provides, for each contained reactor, a place to
     *  write the declaration of the output of that reactor that
     *  is triggering reactions.
     *  @param builder The string builder into which to write the code.
     *  @param structs A map from reactor instantiations to a place to write
     *   struct fields.
     *  @param port The port.
     *  @param reactor The reactor.
     */
    private def generatePortVariablesInReaction(
        StringBuilder builder,
        LinkedHashMap<Instantiation,StringBuilder> structs,
        VarRef port,
        ReactorDecl decl
    ) {
        if (port.variable instanceof Input) {
            generateInputVariablesInReaction(builder, port.variable as Input, decl)
        } else {
            // port is an output of a contained reactor.
            val output = port.variable as Output
            val portName = output.name
            val portStructType = variableStructType(output, port.container.reactorClass)
            
            var structBuilder = structs.get(port.container)
            if (structBuilder === null) {
                structBuilder = new StringBuilder
                structs.put(port.container, structBuilder)
            }
            val reactorName = port.container.name
            // First define the struct containing the output value and indicator
            // of its presence.
            if (!output.isMultiport) {
                pr(structBuilder, '''
                    «portStructType»* «portName»;
                ''')
            } else {
                pr(structBuilder, '''
                    «portStructType»** «portName»;
                    int «portName»_width;
                ''')
                pr(builder, '''
                    «reactorName».«portName»_width = self->__«reactorName».«portName»__width;
                ''')
            }

            // Next, initialize the struct with the current values.
            pr(builder, '''
                «reactorName».«portName» = self->__«reactorName».«portName»;
            ''')
        }
    }

    /** Generate into the specified string builder the code to
     *  initialize local variables for outputs in a reaction function
     *  from the "self" struct.
     *  @param builder The string builder.
     *  @param output The output statement from the AST.
     */
    private def generateOutputVariablesInReaction(
        StringBuilder builder,
        Output output,
        ReactorDecl decl
    ) {
        if (output.type === null && target.requiresTypes === true) {
            reportError(output,
                "Output is required to have a type: " + output.name)
        } else {
            val outputStructType = variableStructType(output, decl)
            // Unfortunately, for the SET macros to work out-of-the-box for
            // multiports, we need an array of *pointers* to the output structs,
            // but what we have on the self struct is an array of output structs.
            // So we have to handle multiports specially here a construct that
            // array of pointers.
            if (!output.isMultiport) {
                pr(builder, '''
                    «outputStructType»* «output.name» = &self->__«output.name»;
                ''')
            } else {
                // Set the _width variable.
                pr(builder, '''
                    int «output.name»_width = self->__«output.name»__width;
                ''')
                pr(builder, '''
                    «outputStructType»* «output.name»[«output.name»_width];
                    for(int i=0; i < «output.name»_width; i++) {
                         «output.name»[i] = &(self->__«output.name»[i]);
                    }
                ''')
            }
        }
    }

    /** 
     * Generate into the specified string builder the code to
     * initialize local variables for sending data to an input
     * of a contained reactor. This will also, if necessary,
     * generate entries for local struct definitions into the
     * struct argument. These entries point to where the data
     * is stored.
     * 
     * @param builder The string builder.
     * @param structs A map from reactor instantiations to a place to write
     *  struct fields.
     * @param definition AST node defining the reactor within which this occurs
     * @param input Input of the contained reactor.
     */
    private def generateVariablesForSendingToContainedReactors(
        StringBuilder builder,
        LinkedHashMap<Instantiation,StringBuilder> structs,
        Instantiation definition,
        Input input
    ) {
        var structBuilder = structs.get(definition)
        if (structBuilder === null) {
            structBuilder = new StringBuilder
            structs.put(definition, structBuilder)
        }
        val inputStructType = variableStructType(input, definition.reactorClass)
        if (!input.isMultiport) {
            pr(structBuilder, '''
                «inputStructType»* «input.name»;
            ''')
            var bankIndex = "";
            if (definition.widthSpec !== null) {
                pr(builder, '''
                    for (int bankIndex = 0; bankIndex < self->__«definition.name»_width; bankIndex++) {
                ''')
                indent(builder);
                bankIndex = "[bankIndex]";
            }
            pr(builder, '''
                «definition.name»«bankIndex».«input.name» = &(self->__«definition.name»«bankIndex».«input.name»);
            ''')
            if (definition.widthSpec !== null) {
                unindent(builder);
                pr(builder, '''
                    }
                ''')
            }
        } else {
            // Contained reactor's input is a multiport.
            pr(structBuilder, '''
                «inputStructType»** «input.name»;
                int «input.name»_width;
            ''')
            // If the contained reactor is a bank, then we have set the
            // pointer for each element of the bank.
            if (definition.widthSpec !== null) {
                pr(builder, '''
                    for (int _i = 0; _i < self->__«definition.name»_width; _i++) {
                        «definition.name»[_i].«input.name» = self->__«definition.name»[_i].«input.name»;
                        «definition.name»[_i].«input.name»_width = self->__«definition.name»[_i].«input.name»__width;
                    }
                ''')
            } else {
                pr(builder, '''
                    «definition.name».«input.name» = self->__«definition.name».«input.name»;
                    «definition.name».«input.name»_width = self->__«definition.name».«input.name»__width;
                ''')
            }
        }
    }

    /**
     * Override the base class to replace a type of form type[] with type*.
     * @param type The type.
     */ 
    override String getTargetType(InferredType type) {
        var result = super.getTargetType(type)
        val matcher = arrayPatternVariable.matcher(result)
        if (matcher.find()) {
            return matcher.group(1) + '*'
        }
        return result
    }
       
    /** Given a type for an input or output, return true if it should be
     *  carried by a lf_token_t struct rather than the type itself.
     *  It should be carried by such a struct if the type ends with *
     *  (it is a pointer) or [] (it is a array with unspecified length).
     *  @param type The type specification.
     */
    protected def isTokenType(InferredType type) {
        if (type.isUndefined)
            return false
        val targetType = type.targetType
        if (targetType.trim.matches("^\\w*\\[\\s*\\]$") || targetType.trim.endsWith('*')) {
            true
        } else {
            false
        }
    }
    
    /** If the type specification of the form type[] or
     *  type*, return the type. Otherwise remove the code delimiter,
     *  if there is one, and otherwise just return the argument
     *  unmodified.
     *  @param type A string describing the type.
     */
    private def rootType(String type) {
        if (type.endsWith(']')) {
            val root = type.indexOf('[')
            type.substring(0, root).trim
        } else if (type.endsWith('*')) {
            type.substring(0, type.length - 1).trim
        } else {
            type.trim
        }
    }

    /** Print the #line compiler directive with the line number of
     *  the specified object.
     *  @param output Where to put the output.
     *  @param eObject The node.
     */
    protected def prSourceLineNumber(StringBuilder output, EObject eObject) {
        var node = NodeModelUtils.getNode(eObject)
        if (node !== null) {
            // For code blocks (delimited by {= ... =}, unfortunately,
            // we have to adjust the offset by the number of newlines before {=.
            // Unfortunately, this is complicated because the code has been
            // tokenized.
            var offset = 0
            if (eObject instanceof Code) {
                offset += 1
            }
            // Extract the filename from eResource, an astonishingly difficult thing to do.
            val resolvedURI = CommonPlugin.resolve(eObject.eResource.URI)
            // pr(output, "#line " + (node.getStartLine() + offset) + ' "' + FileConfig.toFileURI(fileConfig.srcFile) + '"')
            pr(output, "#line " + (node.getStartLine() + offset) + ' "' + resolvedURI + '"')
        }
    }

    /**
     * Print the #line compiler directive with the line number of
     * the specified object.
     * @param eObject The node.
     */
    override prSourceLineNumber(EObject eObject) {
        prSourceLineNumber(code, eObject)
    }

    /**
     * Version of pr() that prints a source line number using a #line
     * prior to each line of the output. Use this when multiple lines of
     * output code are all due to the same source line in the .lf file.
     * @param eObject The AST node that this source line is based on.
     * @param builder The code buffer.
     * @param text The text to append.
     */
    protected def pr(EObject eObject, StringBuilder builder, Object text) {
        var split = text.toString.split("\n")
        for (line : split) {
            prSourceLineNumber(builder, eObject)
            pr(builder, line)
        }
    }

    /** For each output that has a token type (type* or type[]),
     *  create a default token and put it on the self struct.
     *  @param parent The container reactor.
     *  @param federate The federate, or null if there is no federation.
     */
    private def void createDefaultTokens(ReactorInstance parent, FederateInstance federate) {
        for (containedReactor : parent.children) {
            // Do this only for reactors in the federate.
            if (reactorBelongsToFederate(containedReactor, federate)) {
                var nameOfSelfStruct = selfStructName(containedReactor)
                for (output : containedReactor.outputs) {
                    val type = (output.definition as Output).inferredType
                    if (type.isTokenType) {
                        // Create the template token that goes in the trigger struct.
                        // Its reference count is zero, enabling it to be used immediately.
                        var rootType = type.targetType.rootType
                        // If the rootType is 'void', we need to avoid generating the code
                        // 'sizeof(void)', which some compilers reject.
                        val size = (rootType == 'void') ? '0' : '''sizeof(«rootType»)'''
                        if (output instanceof MultiportInstance) {
                            pr('''
                                for (int i = 0; i < «output.width»; i++) {
                                    «nameOfSelfStruct»->__«output.name»[i].token = __create_token(«size»);
                                }
                            ''')
                        } else {
                            pr('''
                                «nameOfSelfStruct»->__«output.name».token = __create_token(«size»);
                            ''')
                        }
                    }
                }
                // In case this is a composite, handle its contained reactors.
                createDefaultTokens(containedReactor, federate)
            }
        }
    }
    
    // Regular expression pattern for array types with specified length.
    // \s is whitespace, \w is a word character (letter, number, or underscore).
    // For example, for "foo[10]", the first match will be "foo" and the second "[10]".
    static final Pattern arrayPatternFixed = Pattern.compile("^\\s*+(\\w+)\\s*(\\[[0-9]+\\])\\s*$");
    
    // Regular expression pattern for array types with unspecified length.
    // \s is whitespace, \w is a word character (letter, number, or underscore).
    // For example, for "foo[]", the first match will be "foo".
    static final Pattern arrayPatternVariable = Pattern.compile("^\\s*+(\\w+)\\s*\\[\\]\\s*$");
    
    protected static var DISABLE_REACTION_INITIALIZATION_MARKER
        = '// **** Do not include initialization code in this reaction.'
        
    public static var UNDEFINED_MIN_SPACING = -1
    
       
    /** Returns the Target enum for this generator */
    override getTarget() {
        return Target.C
    }
        
    override getTargetTimeType() '''interval_t'''
    
    override getTargetTagType() '''tag_t'''
    
    override getTargetTagIntervalType() '''tag_interval_t'''

    override getTargetUndefinedType() '''/* «reportError("undefined type")» */'''

    override getTargetFixedSizeListType(String baseType,
        Integer size) '''«baseType»[«size»]'''
        
    override String getTargetVariableSizeListType(
        String baseType) '''«baseType»[]'''
    
    protected def String getInitializer(ParameterInstance p) {
        
            if (p.type.isList && p.init.size > 1) {
                return p.init.join('{', ', ', '}', [it.targetValue])
            } else {
                return p.init.get(0).targetValue
            }
        
    }
    
    override supportsGenerics() {
        return false
    }
    
    override generateDelayGeneric() {
        throw new UnsupportedOperationException("TODO: auto-generated method stub")
    }
    
    /**
     * Data structure that for each instantiation of a contained
     * reactor, provides a set of input and output ports that trigger
     * reactions of the container, are read by a reaction of the
     * container, or that receive data from a reaction of the container.
     * For each port, this provides a list of reaction indices that
     * are triggered by the port, or an empty list if there are no
     * reactions triggered by the port.
     * @param reactor The contianer.
     * @param federate The federate (used to determine whether a
     *  reaction belongs to the federate).
     */
    private static class InteractingContainedReactors {
        // This horrible data structure is a collection, indexed by instantiation
        // of a contained reactor, of lists, indexed by ports of the contained reactor
        // that are referenced by reactions of the container, of reactions that are
        // triggered by the port of the contained reactor. The list is empty if
        // the port does not trigger reactions but is read by the reaction or
        // is written to by the reaction.
        val portsByContainedReactor = new LinkedHashMap<
            Instantiation,
            LinkedHashMap<
                Port,
                LinkedList<Integer>
            >
        >
        
        /**
         * Scan the reactions of the specified reactor and record which ports are
         * referenced by reactions and which reactions are triggered by such ports.
         */
        new(Reactor reactor, FederateInstance federate) {
            var reactionCount = 0
            for (reaction : reactor.allReactions) {
                if (federate === null || federate.containsReaction(
                    reactor,
                    reaction
                )) {
                    // First, handle reactions that produce data sent to inputs
                    // of contained reactors.
                    for (effect : reaction.effects ?: emptyList) {
                        // If an effect is an input, then it must be an input
                        // of a contained reactor.
                        if (effect.variable instanceof Input) {
                            // This reaction is not triggered by the port, so
                            // we do not add it to the list returned by the following.
                            addPort(effect.container, effect.variable as Input)
                        }
                    }
                    // Second, handle reactions that are triggered by outputs
                    // of contained reactors.
                    for (TriggerRef trigger : reaction.triggers ?: emptyList) {
                        if (trigger instanceof VarRef) {
                            // If an trigger is an output, then it must be an output
                            // of a contained reactor.
                            if (trigger.variable instanceof Output) {
                                val list = addPort(trigger.container, trigger.variable as Output)
                                list.add(reactionCount)
                            }
                        }
                    }
                    // Third, handle reading (but not triggered by)
                    // outputs of contained reactors.
                    for (source : reaction.sources ?: emptyList) {
                        if (source.variable instanceof Output) {
                            // If an source is an output, then it must be an output
                            // of a contained reactor.
                            // This reaction is not triggered by the port, so
                            // we do not add it to the list returned by the following.
                            addPort(source.container, source.variable as Output)
                        }
                    }
                }
                // Increment the reaction count even if not in the federate for consistency.
                reactionCount++
            }
        }
        
        /**
         * Return or create the list to which reactions triggered by the specified port
         * are to be added. This also records that the port is referenced by the
         * container's reactions.
         * @param containedReactor The contained reactor.
         * @param port The port.
         */
        def addPort(Instantiation containedReactor, Port port) {
            // Get or create the entry for the containedReactor.
            var containedReactorEntry = portsByContainedReactor.get(containedReactor)
            if (containedReactorEntry === null) {
                containedReactorEntry = new LinkedHashMap<Port,LinkedList<Integer>>
                portsByContainedReactor.put(containedReactor, containedReactorEntry)
            }
            // Get or create the entry for the port.
            var portEntry = containedReactorEntry.get(port)
            if (portEntry === null) {
                portEntry = new LinkedList<Integer>
                containedReactorEntry.put(port, portEntry)
            }
            return portEntry
        }
        
        /**
         * Return the set of contained reactors that have ports that are referenced
         * by reactions of the container reactor.
         */
        def containedReactors() {
            return portsByContainedReactor.keySet()
        }
        
        /**
         * Return the set of ports of the specified contained reactor that are
         * referenced by reactions of the container reactor. Return an empty
         * set if there are none.
         * @param containedReactor The contained reactor.
         */
        def portsOfInstance(Instantiation containedReactor) {
            var result = null as Set<Port>
            val ports = portsByContainedReactor.get(containedReactor)
            if (ports === null) {
                result = new LinkedHashSet<Port>
            } else {
                result = ports.keySet
            }
            return result
        }
        
        /**
         * Return the indices of the reactions triggered by the specified port
         * of the specified contained reactor or an empty list if there are none.
         * @param containedReactor The contained reactor.
         * @param port The port.
         */
        def LinkedList<Integer> reactionsTriggered(Instantiation containedReactor, Port port) {
            val ports = portsByContainedReactor.get(containedReactor)
            if (ports !== null) {
                val list = ports.get(port)
                if (list !== null) {
                    return list
                }
            }
            return new LinkedList<Integer>
        }
    }
}
