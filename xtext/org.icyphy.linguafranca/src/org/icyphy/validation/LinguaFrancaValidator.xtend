/* Validation checks for Lingua Franca code. */

/*************
 * Copyright (c) 2019-2020, The University of California at Berkeley.

 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:

 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.

 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.

 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES 
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; 
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON 
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS 
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 ***************/
package org.icyphy.validation

import java.util.ArrayList
import java.util.HashSet
import java.util.LinkedList
import java.util.List
import java.util.Set
import org.eclipse.core.resources.IMarker
import org.eclipse.core.resources.IResource
import org.eclipse.core.resources.ResourcesPlugin
import org.eclipse.core.runtime.Path
import org.eclipse.emf.common.util.EList
import org.eclipse.emf.ecore.EStructuralFeature
import org.eclipse.xtext.validation.Check
import org.icyphy.ModelInfo
import org.icyphy.Target
import org.icyphy.TimeValue
import org.icyphy.linguaFranca.Action
import org.icyphy.linguaFranca.ActionOrigin
import org.icyphy.linguaFranca.Assignment
import org.icyphy.linguaFranca.Connection
import org.icyphy.linguaFranca.Deadline
import org.icyphy.linguaFranca.Host
import org.icyphy.linguaFranca.IPV4Host
import org.icyphy.linguaFranca.IPV6Host
import org.icyphy.linguaFranca.Import
import org.icyphy.linguaFranca.ImportedReactor
import org.icyphy.linguaFranca.Input
import org.icyphy.linguaFranca.Instantiation
import org.icyphy.linguaFranca.KeyValuePair
import org.icyphy.linguaFranca.KeyValuePairs
import org.icyphy.linguaFranca.LinguaFrancaPackage.Literals
import org.icyphy.linguaFranca.Model
import org.icyphy.linguaFranca.NamedHost
import org.icyphy.linguaFranca.Output
import org.icyphy.linguaFranca.Parameter
import org.icyphy.linguaFranca.Port
import org.icyphy.linguaFranca.Preamble
import org.icyphy.linguaFranca.Reaction
import org.icyphy.linguaFranca.Reactor
import org.icyphy.linguaFranca.StateVar
import org.icyphy.linguaFranca.TargetDecl
import org.icyphy.linguaFranca.TimeUnit
import org.icyphy.linguaFranca.Timer
import org.icyphy.linguaFranca.Type
import org.icyphy.linguaFranca.TypedVariable
import org.icyphy.linguaFranca.Value
import org.icyphy.linguaFranca.VarRef
import org.icyphy.linguaFranca.Variable
import org.icyphy.linguaFranca.Visibility
import org.icyphy.linguaFranca.WidthSpec

import static extension org.icyphy.ASTUtils.*
import org.icyphy.TargetProperty
import org.icyphy.linguaFranca.STP

/**
 * Custom validation checks for Lingua Franca programs.
 * 
 * Also see: https://www.eclipse.org/Xtext/documentation/303_runtime_concepts.html#validation
 *  
 * @author{Edward A. Lee <eal@berkeley.edu>}
 * @author{Marten Lohstroh <marten@berkeley.edu>}
 * @author{Matt Weber <matt.weber@berkeley.edu>}
 * @author(Christian Menard <christian.menard@tu-dresden.de>}
 * 
 */
class LinguaFrancaValidator extends AbstractLinguaFrancaValidator {

    var Target target
    public var info = new ModelInfo()

    /**
     * Regular expression to check the validity of IPV4 addresses (due to David M. Syzdek).
     */
    static val ipv4Regex = "((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}" +
                                "(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])"

    /**
     * Regular expression to check the validity of IPV6 addresses (due to David M. Syzdek),
     * with minor adjustment to allow up to six IPV6 segments (without truncation) in front
     * of an embedded IPv4-address. 
     **/
    static val ipv6Regex = 
                "(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|" +
                "([0-9a-fA-F]{1,4}:){1,7}:|" + 
                "([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|" +
                "([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|" + 
                "([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|" + 
                "([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|" + 
                "([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|" + 
                 "[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|" + 
                                 ":((:[0-9a-fA-F]{1,4}){1,7}|:)|" +
        "fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|" + 
        "::(ffff(:0{1,4}){0,1}:){0,1}" + ipv4Regex + "|" + 
        "([0-9a-fA-F]{1,4}:){1,4}:"    + ipv4Regex + "|" +
        "([0-9a-fA-F]{1,4}:){1,6}"     + ipv4Regex + ")"                          

    static val usernameRegex = "^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\\$)$"

    static val hostOrFQNRegex = "^([a-z0-9]+(-[a-z0-9]+)*)|(([a-z0-9]+(-[a-z0-9]+)*\\.)+[a-z]{2,})$"

    public static val GLOBALLY_DUPLICATE_NAME = 'GLOBALLY_DUPLICATE_NAME'

    static val spacingViolationPolicies = #['defer', 'drop', 'replace']

    public val List<String> targetPropertyErrors = newLinkedList
    
    public val List<String> targetPropertyWarnings = newLinkedList

    @Check
    def checkImportedReactor(ImportedReactor reactor) {
        if (reactor.unused) {
            warning("Unused reactor class.",
                Literals.IMPORTED_REACTOR__REACTOR_CLASS)
        }

        if (info.instantiationGraph.hasCycles) {
            val cycleSet = newHashSet
            info.instantiationGraph.cycles.forEach[forEach[cycleSet.add(it)]]
            if (dependsOnCycle(reactor.toDefinition, cycleSet, newHashSet)) {
                error("Imported reactor '" + reactor.toDefinition.name +
                    "' has cyclic instantiation in it.",
                    Literals.IMPORTED_REACTOR__REACTOR_CLASS)
            }
        }
    }

    @Check
    def checkImport(Import imp) {
        if (imp.reactorClasses.get(0).toDefinition.eResource.errors.size > 0) {
            error("Error loading resource.", Literals.IMPORT__IMPORT_URI) // FIXME: print specifics.
            return
        }
        
        // FIXME: report error if resource cannot be resolved.
        
        for (reactor : imp.reactorClasses) {
            if (!reactor.unused) {
                return
            }
        }
        warning("Unused import.", Literals.IMPORT__IMPORT_URI)
    }

    // //////////////////////////////////////////////////
    // // Helper functions for checks to be performed on multiple entities
    // Check the name of a feature for illegal substrings.
    private def checkName(String name, EStructuralFeature feature) {

        // Raises an error if the string starts with two underscores.
        if (name.length() >= 2 && name.substring(0, 2).equals("__")) {
            error(UNDERSCORE_MESSAGE + name, feature)
        }

        if (this.target.keywords.contains(name)) {
            error(RESERVED_MESSAGE + name, feature)
        }

        if (this.target == Target.TS) {
            // "actions" is a reserved word within a TS reaction
            if (name.equals("actions")) {
                error(ACTIONS_MESSAGE + name, feature)
            }
        }

    }

    /**
     * Report whether a given reactor has dependencies on a cyclic
     * instantiation pattern. This means the reactor has an instantiation
     * in it -- directly or in one of its contained reactors -- that is 
     * self-referential.
     * @param reactor The reactor definition to find out whether it has any
     * dependencies on cyclic instantiations.
     * @param cycleSet The set of all reactors that are part of an
     * instantiation cycle.
     * @param visited The set of nodes already visited in this graph traversal.
     */
    private def boolean dependsOnCycle(Reactor reactor, Set<Reactor> cycleSet,
        Set<Reactor> visited) {
        val origins = info.instantiationGraph.getUpstreamAdjacentNodes(reactor)
        if (visited.contains(reactor)) {
            return false
        } else {
            visited.add(reactor)
            if (origins.exists[cycleSet.contains(it)] || origins.exists [
                it.dependsOnCycle(cycleSet, visited)
            ]) {
                // Reached a cycle.
                return true
            }
        }
        return false
    }
    
    /**
     * Report whether a given imported reactor is used in this resource or not.
     * @param reactor The imported reactor to check whether it is used.
     */
    private def boolean isUnused(ImportedReactor reactor) {
        val instantiations = reactor.eResource.allContents.filter(Instantiation)
        val subclasses = reactor.eResource.allContents.filter(Reactor)
        if (instantiations.
            forall[it.reactorClass !== reactor && it.reactorClass !== reactor.reactorClass] &&
            subclasses.forall [
                it.superClasses.forall [
                    it !== reactor && it !== reactor.reactorClass
                ]
            ]) {
            return true
        }
        return false
    }
    

    // //////////////////////////////////////////////////
    // // Functions to set up data structures for performing checks.
    // FAST ensures that these checks run whenever a file is modified.
    // Alternatives are NORMAL (when saving) and EXPENSIVE (only when right-click, validate).    

    // //////////////////////////////////////////////////
    // // The following checks are in alphabetical order.
    @Check(FAST)
    def checkAction(Action action) {
        checkName(action.name, Literals.VARIABLE__NAME)
        if (action.origin == ActionOrigin.NONE) {
            error(
                "Action must have modifier `logical` or `physical`.",
                Literals.ACTION__ORIGIN
            )
        }
        if (action.policy !== null &&
            !spacingViolationPolicies.contains(action.policy)) {
            error(
                "Unrecognized spacing violation policy: " + action.policy +
                    ". Available policies are: " +
                    spacingViolationPolicies.join(", ") + ".",
                Literals.ACTION__POLICY)
        }
    }

    @Check(FAST)
    def checkAssignment(Assignment assignment) {
        // If the left-hand side is a time parameter, make sure the assignment has units
        if (assignment.lhs.isOfTimeType) {
            if (assignment.rhs.size > 1) {
                 error("Incompatible type.", Literals.ASSIGNMENT__RHS)
            } else {
                val v = assignment.rhs.get(0)
                if (!v.isValidTime) {
                    if (v.parameter === null) {
                        // This is a value. Check that units are present.
                    error(
                        "Invalid time units: " + assignment.rhs +
                            ". Should be one of " + TimeUnit.VALUES.filter [
                                it != TimeUnit.NONE
                            ], Literals.ASSIGNMENT__RHS)
                    } else {
                        // This is a reference to another parameter. Report problem.
                error(
                    "Cannot assign parameter: " +
                        v.parameter.name + " to " +
                        assignment.lhs.name +
                        ". The latter is a time parameter, but the former is not.",
                    Literals.ASSIGNMENT__RHS)
                    }
                }
            }
            // If this assignment overrides a parameter that is used in a deadline,
            // report possible overflow.
            if (this.target == Target.C &&
                this.info.overflowingAssignments.contains(assignment)) {
                error(
                    "Time value used to specify a deadline exceeds the maximum of " +
                        TimeValue.MAX_LONG_DEADLINE + " nanoseconds.",
                    Literals.ASSIGNMENT__RHS)
            }
        }
        // FIXME: lhs is list => rhs is list
        // lhs is fixed with size n => rhs is fixed with size n
        // FIXME": similar checks for decl/init
        // Specifically for C: list can only be literal or time lists
    }
    
    @Check(FAST)
    def checkWidthSpec(WidthSpec widthSpec) {
        if (this.target != Target.C && this.target != Target.CPP && this.target != Target.Python) {
            error("Multiports and banks are currently only supported by the C and Cpp targets.",
                    Literals.WIDTH_SPEC__TERMS)
        } else {
            for (term : widthSpec.terms) {
                if (term.parameter === null) {
                    if (term.width < 0) {
                        error("Width must be a positive integer.", Literals.WIDTH_SPEC__TERMS)
                    }
                } else {
                    if (this.target != Target.C && this.target != Target.Python) {
                        error("Parameterized widths are currently only supported by the C target.", 
                                Literals.WIDTH_SPEC__TERMS)
                    }
                }
            }
        }
    }

    @Check(FAST)
    def checkConnection(Connection connection) {

        // Report if connection is part of a cycle.
        for (cycle : this.info.reactionGraph.cycles) {
            for (lp : connection.leftPorts) {
                for (rp : connection.rightPorts) {
                    var leftInCycle = false
                    val reactorName = (connection.eContainer as Reactor).name
            
                    if ((lp.container === null && cycle.exists [
                        it.node === lp.variable
                    ]) || cycle.exists [
                        (it.node === lp.variable && it.instantiation === lp.container)
                    ]) {
                        leftInCycle = true
                    }

                    if ((rp.container === null && cycle.exists [
                        it.node === rp.variable
                    ]) || cycle.exists [
                        (it.node === rp.variable && it.instantiation === rp.container)
                    ]) {
                        if (leftInCycle) {
                            // Only report of _both_ referenced ports are in the cycle.
                            error('''Connection in reactor «reactorName» creates ''' + 
                                    '''a cyclic dependency between «lp.toText» and ''' +
                                    '''«rp.toText».''', Literals.CONNECTION__DELAY
                            )
                        }
                    }
                }
            }
        }
        
        // For the C target, since C has such a weak type system, check that
        // the types on both sides of every connection match. For other languages,
        // we leave type compatibility that language's compiler or interpreter.
        if (this.target == Target.C) {
            var type = null as Type
            for (port : connection.leftPorts) {
                // If the variable is not a port, then there is some other
                // error. Avoid a class cast exception.
                if (port.variable instanceof Port) {
                    if (type === null) {
                        type = (port.variable as Port).type
                    } else {
                        // Unfortunately, xtext does not generate a suitable equals()
                        // method for AST types, so we have to manually check the types.
                        if (!sameType(type, (port.variable as Port).type)) {
                            error("Types do not match.", Literals.CONNECTION__LEFT_PORTS)
                        }
                    }
                }
            }
            for (port : connection.rightPorts) {
                // If the variable is not a port, then there is some other
                // error. Avoid a class cast exception.
                if (port.variable instanceof Port) {
                    if (type === null) {
                        type = (port.variable as Port).type
                    } else {
                        if (!sameType(type, (port.variable as Port).type)) {
                            error("Types do not match.", Literals.CONNECTION__RIGHT_PORTS)
                        }
                    }
                }
            }
        }
        
        // Check whether the total width of the left side of the connection
        // matches the total width of the right side. This cannot be determined
        // here if the width is not given as a constant. In that case, it is up
        // to the code generator to check it.
        var leftWidth = 0
        for (port : connection.leftPorts) {
            val width = port.multiportWidthIfLiteral
            if (width < 0 || leftWidth < 0) {
                // Cannot determine the width of the left ports.
                leftWidth = -1
            } else {
                leftWidth += width
            }
        }
        var rightWidth = 0
        for (port : connection.rightPorts) {
            val width = port.multiportWidthIfLiteral
            if (width < 0 || rightWidth < 0) {
                // Cannot determine the width of the left ports.
                rightWidth = -1
            } else {
                rightWidth += width
            }
        }
        
        if (leftWidth !== -1 && rightWidth !== -1 && leftWidth != rightWidth) {
            if (connection.isIterated) {
                if (rightWidth % leftWidth != 0) {
                    // FIXME: The second argument should be Literals.CONNECTION, but
                    // stupidly, xtext will not accept that. There seems to be no way to
                    // report an error for the whole connection statement.
                    warning('''Left width «leftWidth» does not divide right width «rightWidth»''',
                            Literals.CONNECTION__LEFT_PORTS
                    )
                }
            } else {
                // FIXME: The second argument should be Literals.CONNECTION, but
                // stupidly, xtext will not accept that. There seems to be no way to
                // report an error for the whole connection statement.
                warning('''Left width «leftWidth» does not match right width «rightWidth»''',
                        Literals.CONNECTION__LEFT_PORTS
                )
            }
        }
        
        val reactor = connection.eContainer as Reactor
        
        // Make sure the right port is not already an effect of a reaction.
        for (reaction : reactor.reactions) {
            for (effect : reaction.effects) {
                for (rightPort : connection.rightPorts) {
                    if (rightPort.container === effect.container &&
                            rightPort.variable === effect.variable) {
                        error("Cannot connect: Port named '" + effect.variable.name +
                            "' is already effect of a reaction.",
                            Literals.CONNECTION__RIGHT_PORTS
                        )
                    }
                }
            }
        }

        // Check that the right port does not already have some other
        // upstream connection.
        for (c : reactor.connections) {
            if (c !== connection) {
                for (thisRightPort : connection.rightPorts) {
                    for (thatRightPort : c.rightPorts) {
                        if (thisRightPort.container === thatRightPort.container &&
                                thisRightPort.variable === thatRightPort.variable) {
                            error(
                                "Cannot connect: Port named '" + thisRightPort.variable.name +
                                    "' may only appear once on the right side of a connection.",
                                Literals.CONNECTION__RIGHT_PORTS)
                        }
                    }
                }
            }
        }
    }
    
    /**
     * Return true if the two types match. Unfortunately, xtext does not
     * seem to create a suitable equals() method for Type, so we have to
     * do this manually.
     */
    private def boolean sameType(Type type1, Type type2) {
        // Most common case first.
        if (type1.id !== null) {
            if (type1.stars !== null) {
                if (type2.stars === null) return false
                if (type1.stars.length != type2.stars.length) return false
            }
            return (type1.id.equals(type2.id))
        }
        if (type1 === null) {
            if (type2 === null) return true
            return false
        }
        // Type specification in the grammar is:
        // (time?='time' (arraySpec=ArraySpec)?) | ((id=(DottedName) (stars+='*')* ('<' typeParms+=TypeParm (',' typeParms+=TypeParm)* '>')? (arraySpec=ArraySpec)?) | code=Code);
        if (type1.time) {
            if (!type2.time) return false
            // Ignore the arraySpec because that is checked when connection
            // is checked for balance.
            return true
        }
        // Type must be given in a code body.
        return (type1.code.body.equals(type2?.code?.body))
    }

    @Check(FAST)
    def checkDeadline(Deadline deadline) {
        if (this.target == Target.C &&
            this.info.overflowingDeadlines.contains(deadline)) {
            error(
                "Deadline exceeds the maximum of " +
                    TimeValue.MAX_LONG_DEADLINE + " nanoseconds.",
                Literals.DEADLINE__DELAY)
        }
    }
    
    @Check(FAST)
    def checkSTPOffset(STP stp) {
        if (this.target == Target.C &&
            this.info.overflowingDeadlines.contains(stp)) {
            error(
                "Deadline exceeds the maximum of " +
                    TimeValue.MAX_LONG_DEADLINE + " nanoseconds.",
                Literals.DEADLINE__DELAY)
        }
    }
    
    @Check(NORMAL)
    def checkBuild(Model model) {
        val uri = model.eResource?.URI
        if (uri !== null && uri.isPlatform) {
            // Running in INTEGRATED mode. Clear marks.
            // This has to be done here rather than in doGenerate()
            // of GeneratorBase because, apparently, doGenerate() is
            // not called at all if there are marks.
            //val uri = model.eResource.URI
            val iResource = ResourcesPlugin.getWorkspace().getRoot().getFile(
                new Path(uri.toPlatformString(true)))
            try {
                // First argument can be null to delete all markers.
                // But will that delete xtext markers too?
                iResource.deleteMarkers(IMarker.PROBLEM, true,
                    IResource.DEPTH_INFINITE);
            } catch (Exception e) {
                // Ignore, but print a warning.
                println("Warning: Deleting markers in the IDE failed: " + e)
            }
        }
    }

    @Check(FAST)
    def checkInput(Input input) {
        checkName(input.name, Literals.VARIABLE__NAME)
        if (target.requiresTypes) {
            if (input.type === null) {
                error("Input must have a type.", Literals.TYPED_VARIABLE__TYPE)
            }
        }
        
        // mutable has no meaning in C++
        if (input.mutable && this.target == Target.CPP) {
            warning(
                "The mutable qualifier has no meaning for the C++ target and should be removed. " +
                "In C++, any value can be made mutable by calling get_mutable_copy().",
                Literals.INPUT__MUTABLE
            )
        }
        
        // Variable width multiports are not supported (yet?).
        if (input.widthSpec !== null && input.widthSpec.ofVariableLength) {
            error("Variable-width multiports are not supported.", Literals.PORT__WIDTH_SPEC)
        }
    }

    @Check(FAST)
    def checkInstantiation(Instantiation instantiation) {
        checkName(instantiation.name, Literals.INSTANTIATION__NAME)
        val reactor = instantiation.reactorClass.toDefinition
        if (reactor.isMain || reactor.isFederated) {
            error(
                "Cannot instantiate a main (or federated) reactor: " +
                    instantiation.reactorClass.name,
                Literals.INSTANTIATION__REACTOR_CLASS
            )
        }
        
        // Report error if this instantiation is part of a cycle.
        // FIXME: improve error message.
        // FIXME: Also report if there exists a cycle within.
        if (this.info.instantiationGraph.cycles.size > 0) {
            for (cycle : this.info.instantiationGraph.cycles) {
                val container = instantiation.eContainer as Reactor
                if (cycle.contains(container) && cycle.contains(reactor)) {
                    error(
                        "Instantiation is part of a cycle: " +
                            cycle.fold(newArrayList, [ list, r |
                                list.add(r.name);
                                list
                            ]).join(', ') + ".",
                        Literals.INSTANTIATION__REACTOR_CLASS
                    )
                }
            }
        }
        // Variable width multiports are not supported (yet?).
        if (instantiation.widthSpec !== null 
                && instantiation.widthSpec.ofVariableLength
        ) {
            if (this.target == Target.C) {
                warning("Variable-width banks are for internal use only.",
                    Literals.INSTANTIATION__WIDTH_SPEC
                )
            } else {
                error("Variable-width banks are not supported.",
                    Literals.INSTANTIATION__WIDTH_SPEC
                )
            }
        }
    }

    /** Check target parameters, which are key-value pairs. */
    @Check(FAST)
    def checkKeyValuePair(KeyValuePair param) {
        // Check only if the container's container is a Target.
        if (param.eContainer.eContainer instanceof TargetDecl) {

            val prop = TargetProperty.forName(param.name)

            // Make sure the key is valid.
            if (prop === null) {
                warning(
                    "Unrecognized target parameter: " + param.name +
                        ". Recognized parameters are: " +
                        TargetProperty.getOptions().join(", ") + ".",
                    Literals.KEY_VALUE_PAIR__NAME)
            }

            // Check whether the property is supported by the target.
            if (!prop.supportedBy.contains(this.target)) {
                warning(
                    "The target parameter: " + param.name +
                        " is not supported by the " + this.target +
                        " target and will thus be ignored.",
                    Literals.KEY_VALUE_PAIR__NAME)
            }

            // Report problem with the assigned value.
            prop.type.check(param.value, param.name, this)
            targetPropertyErrors.forEach [
                error(it, Literals.KEY_VALUE_PAIR__VALUE)
            ]
            targetPropertyErrors.clear()
            targetPropertyWarnings.forEach [
                warning(it, Literals.KEY_VALUE_PAIR__VALUE)
            ]
            targetPropertyWarnings.clear()
        }
    }

    @Check(FAST)
    def checkOutput(Output output) {
        checkName(output.name, Literals.VARIABLE__NAME)
        if (this.target.requiresTypes) {
            if (output.type === null) {
                error("Output must have a type.", Literals.TYPED_VARIABLE__TYPE)
            }
        }
        
        // Variable width multiports are not supported (yet?).
        if (output.widthSpec !== null && output.widthSpec.ofVariableLength) {
            error("Variable-width multiports are not supported.", Literals.PORT__WIDTH_SPEC)
        }
    }

    @Check(NORMAL)
    def checkModel(Model model) {
        info.update(model)
    }

    @Check(FAST)
    def checkParameter(Parameter param) {
        checkName(param.name, Literals.PARAMETER__NAME)

        if (param.init.exists[it.parameter !== null]) {
            // Initialization using parameters is forbidden.
            error("Parameter cannot be initialized using parameter.",
                Literals.PARAMETER__INIT)
        }
        
        if (param.init === null || param.init.size == 0) {
            // All parameters must be initialized.
            error("Uninitialized parameter.", Literals.PARAMETER__INIT)
        } else if (param.isOfTimeType) {
             // We do additional checks on types because we can make stronger
             // assumptions about them.
             
             // If the parameter is not a list, cannot be initialized
             // using a one.
             if (param.init.size > 1 && param.type.arraySpec === null) {
                error("Time parameter cannot be initialized using a list.",
                    Literals.PARAMETER__INIT)
            } else {
                // The parameter is a singleton time.
                val init = param.init.get(0)
                if (init.time === null) {
                    if (init !== null && !init.isZero) {
                        if (init.isInteger) {
                            error("Missing time units. Should be one of " +
                                TimeUnit.VALUES.filter [
                                    it != TimeUnit.NONE
                                ], Literals.PARAMETER__INIT)
                        } else {
                            error("Invalid time literal.",
                                Literals.PARAMETER__INIT)
                        }
                    }
                } // If time is not null, we know that a unit is also specified.    
            }
        } else if (this.target.requiresTypes) {
            // Report missing target type.
            if (param.inferredType.isUndefined()) {
                error("Type declaration missing.", Literals.PARAMETER__TYPE)
            }
        }

        if (this.target == Target.C &&
            this.info.overflowingParameters.contains(param)) {
            error(
                "Time value used to specify a deadline exceeds the maximum of " +
                    TimeValue.MAX_LONG_DEADLINE + " nanoseconds.",
                Literals.PARAMETER__INIT)
        }
    }

    @Check(FAST)
    def checkPreamble(Preamble preamble) {
        if (this.target == Target.CPP) {
            if (preamble.visibility == Visibility.NONE) {
                error(
                    "Preambles for the C++ target need a visibility qualifier (private or public)!",
                    Literals.PREAMBLE__VISIBILITY
                )
            } else if (preamble.visibility == Visibility.PRIVATE) {
                val container = preamble.eContainer
                if (container !== null && container instanceof Reactor) {
                    val reactor = container as Reactor
                    if (reactor.isGeneric) {
                        warning(
                            "Private preambles in generic reactors are not truly private. " +
                                "Since the generated code is placed in a *_impl.hh file, it will " +
                                "be visible on the public interface. Consider using a public " +
                                "preamble within the reactor or a private preamble on file scope.",
                            Literals.PREAMBLE__VISIBILITY)
                    }
                }
            }
        } else if (preamble.visibility != Visibility.NONE) {
            warning(
                '''The «preamble.visibility» qualifier has no meaning for the «this.target.name» target. It should be removed.''',
                Literals.PREAMBLE__VISIBILITY
            )
        }
    }

	@Check(FAST)
    def checkReaction(Reaction reaction) {

        if (reaction.triggers === null || reaction.triggers.size == 0) {
            warning("Reaction has no trigger.", Literals.REACTION__TRIGGERS)
        }
        val triggers = new HashSet<Variable>
        // Make sure input triggers have no container and output sources do.
        for (trigger : reaction.triggers) {
            if (trigger instanceof VarRef) {
                triggers.add(trigger.variable)
                if (trigger.variable instanceof Input) {
                    if (trigger.container !== null) {
                        error('''Cannot have an input of a contained reactor as a trigger: «trigger.container.name».«trigger.variable.name»''',
                            Literals.REACTION__TRIGGERS)
                    }
                } else if (trigger.variable instanceof Output) {
                    if (trigger.container === null) {
                        error('''Cannot have an output of this reactor as a trigger: «trigger.variable.name»''',
                            Literals.REACTION__TRIGGERS)
                    }
                }
            }
        }

		// Make sure input sources have no container and output sources do.
        // Also check that a source is not already listed as a trigger.
        for (source : reaction.sources) {
            if (triggers.contains(source.variable)) {
                error('''Source is already listed as a trigger: «source.variable.name»''',
                    Literals.REACTION__SOURCES)
            }
            if (source.variable instanceof Input) {
                if (source.container !== null) {
                    error('''Cannot have an input of a contained reactor as a source: «source.container.name».«source.variable.name»''',
                        Literals.REACTION__SOURCES)
                }
            } else if (source.variable instanceof Output) {
                if (source.container === null) {
                    error('''Cannot have an output of this reactor as a source: «source.variable.name»''',
                        Literals.REACTION__SOURCES)
                }
            }
        }

        // Make sure output effects have no container and input effects do.
        for (effect : reaction.effects) {
            if (effect.variable instanceof Input) {
                if (effect.container === null) {
                    error('''Cannot have an input of this reactor as an effect: «effect.variable.name»''',
                        Literals.REACTION__EFFECTS)
                }
            } else if (effect.variable instanceof Output) {
                if (effect.container !== null) {
                    error('''Cannot have an output of a contained reactor as an effect: «effect.container.name».«effect.variable.name»''',
                        Literals.REACTION__EFFECTS)
                }
            }
        }

        // Report error if this reaction is part of a cycle.
        for (cycle : this.info.reactionGraph.cycles) {
            val reactor = (reaction.eContainer) as Reactor
            if (cycle.exists[it.node === reaction]) {
                // Report involved triggers.
                val trigs = new LinkedList()
                reaction.triggers.forEach [ t |
                    (t instanceof VarRef && cycle.exists [ c |
                        c.node === (t as VarRef).variable
                    ]) ? trigs.add((t as VarRef).toText) : {
                    }
                ]
                if (trigs.size > 0) {
                    error('''Reaction triggers involved in cyclic dependency in reactor «reactor.name»: «trigs.join(', ')».''',
                        Literals.REACTION__TRIGGERS)
                }

                // Report involved sources.
                val sources = new LinkedList()
                reaction.sources.forEach [ t |
                    (cycle.exists[c|c.node === t.variable])
                        ? sources.add(t.toText)
                        : {
                    }
                ]
                if (sources.size > 0) {
                    error('''Reaction sources involved in cyclic dependency in reactor «reactor.name»: «sources.join(', ')».''',
                        Literals.REACTION__SOURCES)
                }

                // Report involved effects.
                val effects = new LinkedList()
                reaction.effects.forEach [ t |
                    (cycle.exists[c|c.node === t.variable])
                        ? effects.add(t.toText)
                        : {
                    }
                ]
                if (effects.size > 0) {
                    error('''Reaction effects involved in cyclic dependency in reactor «reactor.name»: «effects.join(', ')».''',
                        Literals.REACTION__EFFECTS)
                }

                if (trigs.size + sources.size == 0) {
                    error(
                    '''Cyclic dependency due to preceding reaction. Consider reordering reactions within reactor «reactor.name» to avoid causality loop.''',
                        reaction.eContainer,
                    Literals.REACTOR__REACTIONS,
                    reactor.reactions.indexOf(reaction))    
                } else if (effects.size == 0) {
                    error(
                    '''Cyclic dependency due to succeeding reaction. Consider reordering reactions within reactor «reactor.name» to avoid causality loop.''',
                    reaction.eContainer,
                    Literals.REACTOR__REACTIONS,
                    reactor.reactions.indexOf(reaction))
                }
                // Not reporting reactions that are part of cycle _only_ due to reaction ordering.
                // Moving them won't help solve the problem.
            }
        }
    // FIXME: improve error message. 
    }

    @Check(FAST)
    def checkReactor(Reactor reactor) {
        checkName(reactor.name, Literals.REACTOR_DECL__NAME)
        
        // C++ reactors may not be called 'preamble'
        if (this.target == Target.CPP && reactor.name.equalsIgnoreCase("preamble")) {
            error(
                "Reactor cannot be named '" + reactor.name + "'",
                Literals.REACTOR_DECL__NAME
            )
        }
        
        if (reactor.host !== null) {
            if (!reactor.isFederated) {
                error(
                    "Cannot assign a host to reactor '" + reactor.name + 
                    "' because it is not federated.",
                    Literals.REACTOR__HOST
                )
            }
        }
        // FIXME: In TypeScript, there are certain classes that a reactor class should not collide with
        // (essentially all the classes that are imported by default).

        var variables = new ArrayList()
        variables.addAll(reactor.inputs)
        variables.addAll(reactor.outputs)
        variables.addAll(reactor.actions)
        variables.addAll(reactor.timers)
                
        // Perform checks on super classes.
        for (superClass : reactor.superClasses ?: emptyList) {
            var conflicts = new HashSet()
            
            // Detect input conflicts
            checkConflict(superClass.toDefinition.inputs, reactor.inputs, variables, conflicts)
            // Detect output conflicts
            checkConflict(superClass.toDefinition.outputs, reactor.outputs, variables, conflicts)
            // Detect output conflicts
            checkConflict(superClass.toDefinition.actions, reactor.actions, variables, conflicts)
            // Detect conflicts
            for (timer : superClass.toDefinition.timers) {
                if (timer.hasNameConflict(variables.filter[it | !reactor.timers.contains(it)])) {
                    conflicts.add(timer)
                } else {
                    variables.add(timer)
                }
            }
            
            // Report conflicts.
            if (conflicts.size > 0) {
                val names = new ArrayList();
                conflicts.forEach[it | names.add(it.name)]
                error(
                '''Cannot extend «superClass.name» due to the following conflicts: «names.join(',')».''',
                Literals.REACTOR__SUPER_CLASSES
                )    
            }
        }
        // Do not allow multiple main/federated reactors.
        if (this.info.numberOfMainReactors > 1) {
            var attribute = Literals.REACTOR__MAIN
            if (reactor.isFederated) {
               attribute = Literals.REACTOR__FEDERATED
            }
            if (reactor.isMain || reactor.isFederated) {
                error(
                    "Multiple definitions of main or federated reactor.",
                    attribute
                )
            }
        }
    }
    /** 
     * For each input, report a conflict if:
     *   1) the input exists and the type doesn't match; or
     *   2) the input has a name clash with variable that is not an input.
     * @param superVars List of typed variables of a particular kind (i.e.,
     * inputs, outputs, or actions), found in a super class.
     * @param sameKind Typed variables of the same kind, found in the subclass.
     * @param allOwn Accumulator of non-conflicting variables incorporated in the
     * subclass.
     * @param conflicts Set of variables that are in conflict, to be used by this
     * function to report conflicts.
     */
    def <T extends TypedVariable> checkConflict (EList<T> superVars,
        EList<T> sameKind, List<Variable> allOwn,
        HashSet<Variable> conflicts) {
        for (superVar : superVars) {
                val match = sameKind.findFirst [ it |
                it.name.equals(superVar.name)
            ]
            val rest = allOwn.filter[it|!sameKind.contains(it)]
            if ((match !== null && superVar.type !== match.type) || superVar.hasNameConflict(rest)) {
                conflicts.add(superVar)
            } else {
                allOwn.add(superVar)
            }
        }
    }

    /**
     * Report whether the name of the given element matches any variable in
     * the ones to check against.
     * @param element The element to compare against all variables in the given iterable.
     * @param toCheckAgainst Iterable variables to compare the given element against.
     */
    def boolean hasNameConflict(Variable element,
        Iterable<Variable> toCheckAgainst) {
        if (toCheckAgainst.filter[it|it.name.equals(element.name)].size > 0) {
            return true
        }
        return false
    }

    @Check(FAST)
    def checkHost(Host host) {
        val addr = host.addr
        val user = host.user
        if (user !== null && !user.matches(usernameRegex)) {
            warning(
                "Invalid user name.",
                Literals.HOST__USER
            )
        }
        if (host instanceof IPV4Host && !addr.matches(ipv4Regex)) {
            warning(
                "Invalid IP address.",
                Literals.HOST__ADDR
            )
        } else if (host instanceof IPV6Host && !addr.matches(ipv6Regex)) {
            warning(
                "Invalid IP address.",
                Literals.HOST__ADDR
            )
        } else if (host instanceof NamedHost && !addr.matches(hostOrFQNRegex)) {
            warning(
                "Invalid host name or fully qualified domain name.",
                Literals.HOST__ADDR
            )
        }
    }

    @Check(FAST)
    def checkState(StateVar stateVar) {
        checkName(stateVar.name, Literals.STATE_VAR__NAME)

        if (stateVar.isOfTimeType) {
            // If the state is declared to be a time,
            // make sure that it is initialized correctly.
            if (stateVar.init !== null) {
                for (init : stateVar.init) {
                    if (stateVar.type !== null && stateVar.type.isTime &&
                        !init.isValidTime) {
                        if (stateVar.isParameterized) {
                            error(
                                "Referenced parameter does not denote a time.",
                                Literals.STATE_VAR__INIT)
                        } else {
                            if (init !== null && !init.isZero) {
                                if (init.isInteger) {
                                    error(
                                        "Missing time units. Should be one of " +
                                            TimeUnit.VALUES.filter [
                                                it != TimeUnit.NONE
                                            ], Literals.STATE_VAR__INIT)
                                } else {
                                    error("Invalid time literal.",
                                        Literals.STATE_VAR__INIT)
                                }
                            }
                        }
                    }
                }
            }
        } else if (this.target.requiresTypes && stateVar.inferredType.isUndefined) {
            // Report if a type is missing
            error("State must have a type.", Literals.STATE_VAR__TYPE)
        }

        if (this.target == Target.C && stateVar.init.size > 1) {
            // In C, if initialization is done with a list, elements cannot
            // refer to parameters.
            if (stateVar.init.exists[it.parameter !== null]) {
                error("List items cannot refer to a parameter.",
                    Literals.STATE_VAR__INIT)
            }
        }

    }

    @Check(FAST)
    def checkTargetDecl(TargetDecl target) {
        if (!Target.hasForName(target.name)) {
            warning("Unrecognized target: " + target.name,
                Literals.TARGET_DECL__NAME)
        } else {
            this.target = Target.forName(target.name);
        }
    }

    /**
     * Check for consistency of the target properties, which are
     * defined as KeyValuePairs.
     *
     * @param targetProperties The target properties defined
     *  in the current Lingua Franca program.
     */
    @Check(EXPENSIVE)
    def checkTargetProperties(KeyValuePairs targetProperties) {

        if (targetProperties.pairs.exists(
            pair |
                // Check to see if fast is defined
                TargetProperty.forName(pair.name) == TargetProperty.FAST
        )) {
            if (info.model.reactors.exists(
                reactor |
                    // Check to see if the program has a federated reactor and if there is a physical connection
                    // defined.
                    reactor.isFederated && reactor.connections.exists(connection|connection.isPhysical)
            )) {
                error(
                    "The fast target property is incompatible with physical connections.",
                    Literals.KEY_VALUE_PAIRS__PAIRS
                )
            }

            if (info.model.reactors.exists(
                reactor |
                    // Check to see if the program has physical actions
                    reactor.isFederated && reactor.actions.exists(action|(action.origin == ActionOrigin.PHYSICAL))
            )) {
                error(
                    "The fast target property is incompatible with physical actions.",
                    Literals.KEY_VALUE_PAIRS__PAIRS
                )
            }

        }
        if (targetProperties.pairs.exists(
            pair |
                // Check to see if clock-sync is defined
                TargetProperty.forName(pair.name) == TargetProperty.CLOCK_SYNC
        )) {

            if (info.model.reactors.exists(
                reactor |
                    // Check to see if the program has a federated reactor and if there is a physical connection
                    // defined.
                    reactor.isFederated
            ) == false) {
                warning(
                    "The clock-sync target property is incompatible with non-federated programs.",
                    Literals.KEY_VALUE_PAIRS__PAIRS
                )
            }
        }
    }

    @Check(FAST)
    def checkValueAsTime(Value value) {
        val container = value.eContainer

        if (container instanceof Timer || container instanceof Action ||
            container instanceof Connection || container instanceof Deadline) {

            // If parameter is referenced, check that it is of the correct type.
            if (value.parameter !== null) {
                if (!value.parameter.isOfTimeType && target.requiresTypes === true) {
                    error("Parameter is not of time type",
                        Literals.VALUE__PARAMETER)
                }
            } else if (value.time === null) {
                if (value.literal !== null && !value.literal.isZero) {
                    if (value.literal.isInteger) {
                            error("Missing time units. Should be one of " +
                                TimeUnit.VALUES.filter [
                                    it != TimeUnit.NONE
                                ], Literals.VALUE__LITERAL)
                        } else {
                            error("Invalid time literal.",
                                Literals.VALUE__LITERAL)
                        }
                } else if (value.code !== null && !value.code.isZero) {
                    if (value.code.isInteger) {
                            error("Missing time units. Should be one of " +
                                TimeUnit.VALUES.filter [
                                    it != TimeUnit.NONE
                                ], Literals.VALUE__CODE)
                        } else {
                            error("Invalid time literal.",
                                Literals.VALUE__CODE)
                        }
                }
            }
        }
    }
    
    @Check(FAST)
    def checkTimer(Timer timer) {
        checkName(timer.name, Literals.VARIABLE__NAME)
    }
    
    @Check(FAST)
    def checkType(Type type) {
        // FIXME: disallow the use of generics in C
        if (this.target == Target.CPP) {
            if (type.stars.size > 0) {
                warning(
                    "Raw pointers should be avoided in conjunction with LF. Ports " +
                    "and actions implicitly use smart pointers. In this case, " +
                    "the pointer here is likely not needed. For parameters and state " +
                    "smart pointers should be used explicitly if pointer semantics " +
                    "are really needed.",
                    Literals.TYPE__STARS
                )
            }
        }
        else if (this.target == Target.Python) {
            if (type !== null) {               
                error(
                    "Types are not allowed in the Python target",
                    Literals.TYPE__ID
                )
            }
        }
    }
        
    static val UNDERSCORE_MESSAGE = "Names of objects (inputs, outputs, actions, timers, parameters, state, reactor definitions, and reactor instantiation) may not start with \"__\": "
    static val ACTIONS_MESSAGE = "\"actions\" is a reserved word for the TypeScript target for objects (inputs, outputs, actions, timers, parameters, state, reactor definitions, and reactor instantiation): "
    static val RESERVED_MESSAGE = "Reserved words in the target language are not allowed for objects (inputs, outputs, actions, timers, parameters, state, reactor definitions, and reactor instantiation): "

}
